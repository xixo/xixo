//go:build unix

package folders

import "syscall"

const noFollow = syscall.O_NOFOLLOW
