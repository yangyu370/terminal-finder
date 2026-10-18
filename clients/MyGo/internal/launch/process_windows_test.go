package launch

import (
	"os/exec"
	"testing"
)

func TestManagedCoreDoesNotCreateConsoleWindow(t *testing.T) {
	cmd := exec.Command("core.exe")
	configureManagedProcess(cmd)
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.HideWindow || cmd.SysProcAttr.CreationFlags&0x08000000 == 0 {
		t.Fatal("GUI sidecar must be created without a console window")
	}
}
