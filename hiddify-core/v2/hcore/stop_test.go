package hcore

import (
	"errors"
	"reflect"
	"testing"
)

type recordingStartedService struct {
	closeServiceError error
	calls             []string
}

type recordingCloser struct {
	closed int
}

func (c *recordingCloser) Close() error {
	c.closed++
	return errors.New("ignored close error")
}

func (s *recordingStartedService) CloseService() error {
	s.calls = append(s.calls, "close_service")
	return s.closeServiceError
}

func TestClosePreviousCoreLogFactory(t *testing.T) {
	closePreviousCoreLogFactory(nil)
	closer := new(recordingCloser)
	closePreviousCoreLogFactory(closer)
	if closer.closed != 1 {
		t.Fatalf("close count = %d, want 1", closer.closed)
	}
}

func (s *recordingStartedService) Close() {
	s.calls = append(s.calls, "close_observers")
}

func TestCloseStartedServiceAlwaysClosesObservers(t *testing.T) {
	closeError := errors.New("close service")
	for _, test := range []struct {
		name string
		err  error
	}{
		{name: "success"},
		{name: "service error", err: closeError},
	} {
		t.Run(test.name, func(t *testing.T) {
			service := &recordingStartedService{closeServiceError: test.err}
			gotErr := closeStartedService(service)
			if !errors.Is(gotErr, test.err) {
				t.Fatalf("error = %v, want %v", gotErr, test.err)
			}
			wantCalls := []string{"close_service", "close_observers"}
			if !reflect.DeepEqual(service.calls, wantCalls) {
				t.Fatalf("calls = %v, want %v", service.calls, wantCalls)
			}
		})
	}
}
