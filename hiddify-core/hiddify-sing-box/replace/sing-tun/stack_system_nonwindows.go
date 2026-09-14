//go:build !windows

package tun

import (
	"errors"

	"golang.org/x/sys/unix"
)

func (s *System) startWindowsFirewall() error {
	return nil
}

func (s *System) closeWindowsFirewall() error {
	return nil
}

func retryableListenError(err error) bool {
	return errors.Is(err, unix.EADDRNOTAVAIL)
}
