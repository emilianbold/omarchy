# Per-user setup for ARMv7 targets, run in place of install/user/all.sh by
# omarchy-provision-user.
#
# Same shape as the system chain: the leaves that work here are the x86_64 ones,
# and what is left out is left out for a reason.
#
# mise-work.sh and mise.sh are the omission. mise reaches Omarchy as mise-bin,
# which pkgs.omarchy.org builds for x86_64 only, and the tools mise.sh then
# installs -- claude, codex, gh, opencode and the rest -- publish x86_64 and
# aarch64 binaries, not armv7h. Sourcing them here fails the whole user phase on
# `mise: command not found` and takes the leaves after it down too.
#
# The x86 hardware leaves are also absent: every one of them is gated on a DMI
# match for a laptop this is not.

run_logged "$OMARCHY_INSTALL/user/theme.sh"
run_logged "$OMARCHY_INSTALL/user/chromium.sh"
run_logged "$OMARCHY_INSTALL/user/git.sh"
run_logged "$OMARCHY_INSTALL/user/xcompose.sh"
run_logged "$OMARCHY_INSTALL/user/default-keyring.sh"
