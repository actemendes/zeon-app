//go:build android && zeon_route_validation

package hcore

/*
#cgo LDFLAGS: -llog
#include <android/log.h>
#include <stdlib.h>

static void zeonEmitRouteValidation(const char *message) {
	__android_log_write(ANDROID_LOG_WARN, "ZEON_ROUTE_VALIDATION", message);
}
*/
import "C"

import "unsafe"

func emitValidationLogcat(message string) {
	cMessage := C.CString(message)
	defer C.free(unsafe.Pointer(cMessage))
	C.zeonEmitRouteValidation(cMessage)
}
