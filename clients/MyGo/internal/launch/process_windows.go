package launch

import (
	"os/exec"
	"syscall"
)

// The GUI owns the visible terminal; core only needs its redirected pipes.
func configureManagedProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
}
