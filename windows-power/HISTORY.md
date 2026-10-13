# History

**2026-09-24: shortcuts built.** The goal was one-click switching between Power Saver, Balanced and Ultimate Performance. High Performance was left out on request because it overlaps with Ultimate. The switcher was written to look plans up by name, since Ultimate Performance has a per-machine GUID. The installer draws its own icons, so nothing has to be downloaded. All three shortcuts were tested switching, and the PC was left on Balanced. While checking the plans, it turned out Balanced now slept after 120 minutes rather than the 15 minutes older notes assumed, and the notes were corrected.

**2026-09-25: the wake-reporting lie.** During Wake-on-LAN testing for the nightly backup, the system's last-wake report kept saying "power button" for genuine network wakes. Timing the wakes showed the packet was doing the work, because the firmware reports PCIe wake through the power-button event. From then on, wake problems were diagnosed by timing.

**2026-10-03: the PC that wouldn't sleep.** The PC stayed awake all night. Reading the logs showed two separate causes. Until shortly after midnight it was on Ultimate Performance, which never sleeps. After a shortcut switched it to Power Saver, it still never even *attempted* to sleep. The power-request list showed a system-required request from a USB headset's audio driver: chat, wallpaper and launcher apps kept an audio stream open. The owner chose a per-driver override so Windows ignores that device's audio stream for sleep, accepting that the PC can now sleep mid-music without input. A second, legacy kernel request was noted as the next candidate if the problem returned.

**2026-10-13: public version.** User-specific install paths and documentation pointers were removed. The scripts are otherwise unchanged.
