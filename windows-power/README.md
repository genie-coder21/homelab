# Windows power-plan shortcuts

One-click desktop shortcuts on the Windows gaming-pc for switching between **Power Saver**, **Balanced** and **Ultimate Performance**. Each plan has its own coloured letter icon, and a silent toast confirms the switch. No admin rights are needed.

## Why

The gaming-pc does double duty. It is a gaming machine and also a sleep-when-idle box that the server wakes for backups and GPU work. Ultimate Performance never sleeps, which is right while gaming and wrong overnight. Digging through Control Panel every time meant it got left on the wrong plan, so switching needed to be a single click.

## How it works

- **`Set-PowerPlan.ps1 -Plan "<name>"`** looks the plan up **by name** in the system's power-plan list, activates it and shows a short, silent toast. On failure it shows a toast saying what went wrong.
- **`Install-PowerPlanShortcuts.ps1`** copies the switcher into the user's profile, draws a 256 px letter-in-a-circle icon for each plan with System.Drawing and writes it as a single-image `.ico`, then creates a "Power Plans" folder on the desktop with one shortcut per plan. The shortcuts launch hidden PowerShell minimised, so no console window flashes. Re-running it is safe because it overwrites its own files.

To change which plans appear, edit the `$Plans` table at the top of the installer. The name must match what Windows lists exactly.

## Lessons learned

- **Look up plans by name, not GUID.** The Ultimate Performance plan is created per machine, and its GUID differs from one PC to the next. Hard-coded GUIDs break on the next machine.
- **A power plan doesn't guarantee the PC sleeps.** One night the PC stayed awake on Power Saver with a 15-minute sleep timer. The cause was a USB audio headset's driver holding a "system required" request because background apps kept an audio stream open. Windows' power-request list shows exactly what is blocking sleep, and a per-driver request override fixed it. The side effect, accepted, is that the PC can now sleep in the middle of music if there's no input.
- **The "last wake source" report can lie.** On this board it reported the power button even for a genuine Wake-on-LAN wake, because the firmware signals PCIe wake through the power-button event. Diagnose wake problems by timing, not by that report.
- **Keep-awake for remote workloads should not touch power settings.** Remote jobs that need the PC awake use a separate holder (an execution-state request with its own idle timeout). Turning it off can never leave sleep disabled, and these shortcuts keep working independently of it.
