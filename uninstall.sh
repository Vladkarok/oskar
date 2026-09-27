#!/usr/bin/env bash
# Uninstalls the SOURCE install's files: the helper binary, the user unit
# and the ~/.local/bin lifecycle symlink. Deactivation (plugin disable,
# unit stop, registration unlink) is the lifecycle command's job and runs
# FIRST, but only when this checkout's registration is the live one — a
# packaged install (or another checkout) must not be switched off by
# uninstalling this. In a mixed state (registration at this checkout
# while the packaged unit is the one systemd runs) the teardown stops
# the packaged unit — recoverable with `oskar setup`. Config and the
# panel's state are never touched; the install record under
# ~/.local/state/oskar forgets each path removed here and goes with the
# last one. Package files belong to pacman; run `oskar teardown` there
# instead.
#
# A file goes only when the install record proves it is what OSKar wrote
# and unchanged, and only when nothing that stays still needs it: an
# edited unit that still runs the helper keeps the helper, so no enabled
# unit is left pointing at a missing binary. `--force` is consent to
# finish anyway: what does not match the record is moved aside (nothing
# is deleted), all or nothing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reg="$HOME/.config/omarchy/plugins/io.github.vladkarok.oskar"
unit="$HOME/.config/systemd/user/oskar.service"
binary="$HOME/.local/libexec/oskar-daemon"
cli="$HOME/.local/bin/oskar"

force=""
case "${1:-}" in
  "") ;;
  --force) force=1; [[ $# -eq 1 ]] || { echo "usage: uninstall.sh [--force]" >&2; exit 2; } ;;
  *) echo "usage: uninstall.sh [--force]" >&2; exit 2 ;;
esac

# Every decision below asks the install record through bin/oskar; without
# it nothing can be proven, so nothing is switched off or removed.
if [[ ! -f "$here/bin/oskar" || ! -r "$here/bin/oskar" ]]; then
  echo "uninstall.sh: $here/bin/oskar is missing or unreadable, so the install record cannot be consulted; nothing was changed" >&2
  exit 1
fi
oskar_cmd() { bash "$here/bin/oskar" "$@"; }
ours() { oskar_cmd record matches "$1" >/dev/null 2>&1; }
present() { [[ -e "$1" || -L "$1" ]]; }

# Whether a unit file that stays still runs the helper at its installed
# path. Read only to decide what to KEEP: an unreadable unit counts as
# running it.
unit_runs_helper() {
  [[ -f "$1" ]] || return 1
  [[ -r "$1" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == ExecStart=* ]] || continue
    [[ "$line" == *"%h/.local/libexec/oskar-daemon"* \
      || "$line" == *"$HOME/.local/libexec/oskar-daemon"* ]] && return 0
  done < "$1"
  return 1
}

state_line() {
  local enabled active
  enabled="$(systemctl --user is-enabled oskar.service 2>/dev/null || true)"
  active="$(systemctl --user is-active oskar.service 2>/dev/null || true)"
  echo "uninstall.sh: oskar.service is now ${enabled:-unknown} and ${active:-unknown}" >&2
  if [[ "$active" == active ]]; then
    echo "uninstall.sh: its running helper stops at the end of the session, or now with: systemctl --user stop oskar.service" >&2
  fi
}

# The helper binary, the unit and the command are SHARED paths: whichever
# checkout installed LAST uses them, and the command symlink names that
# checkout. Removing them while another checkout's install is live would
# gut its service mid-flight, so this checkout removes them only while
# the command points here.
cli_owner="$(readlink -f "$cli" 2>/dev/null || true)"
if [[ "$cli_owner" != "$(readlink -f "$here/bin/oskar")" ]]; then
  if [[ "$(readlink -f "$reg" 2>/dev/null || true)" == "$(readlink -f "$here")" ]]; then
    oskar_cmd teardown
  else
    echo "uninstall.sh: registration does not point at this checkout; leaving the live install alone" >&2
  fi
  if present "$cli" || present "$binary" || present "$unit"; then
    echo "uninstall.sh: the shared helper/service/CLI belong to another install${cli_owner:+ ($cli_owner)}${cli_owner:+ or to a checkout that is gone}; leaving them in place" >&2
    echo "uninstall.sh: this checkout's files are gone with the checkout itself" >&2
    if [[ "$(readlink -f "$reg" 2>/dev/null || true)" == "$(readlink -f "$here")" && -L "$reg" ]]; then
      echo "uninstall.sh: the registration is a stale symlink to this checkout; remove it with: rm '$reg'" >&2
    fi
  else
    echo "Source install already absent. Config and state preserved."
  fi
  exit 0
fi

# ---- decide everything before anything changes ----
remove=()    # recorded and unchanged: removed
unmatched=() # present, not matching the record
for path in "$unit" "$binary" "$cli"; do
  if ours "$path"; then
    remove+=("$path")
  elif present "$path"; then
    unmatched+=("$path")
  fi
done

if ((${#remove[@]} == 0 && ${#unmatched[@]})) && [[ -z "$force" ]]; then
  echo "uninstall.sh: none of these files matches OSKar's install record:" >&2
  printf '  %s\n' "${unmatched[@]}" >&2
  echo "This install was made by an OSKar version older than its install record, or the files were changed since. Nothing was removed or switched off." >&2
  echo "Either run ./install.sh --force once (it moves them aside and deletes nothing) and then uninstall.sh, or run uninstall.sh --force (it moves them aside and deletes nothing)." >&2
  exit 3
fi

aside=()   # --force: present, not matching, moved aside
held=""    # the helper kept because a unit that stays runs it
held_cli="" # and the command kept with it, so uninstall.sh can finish
if [[ -n "$force" ]]; then
  aside=(${unmatched[@]+"${unmatched[@]}"})
  unmatched=()
elif present "$unit" && ! ours "$unit" && unit_runs_helper "$unit"; then
  # The command stays with the helper: it is what lets this checkout's
  # uninstall.sh finish the job later (it names the checkout).
  keep=()
  for path in ${remove[@]+"${remove[@]}"}; do
    if [[ "$path" == "$binary" ]]; then held=1; fi
  done
  for path in ${remove[@]+"${remove[@]}"}; do
    case "$path" in
      "$binary") ;;
      "$cli") if [[ -n "$held" ]]; then held_cli=1; else keep+=("$path"); fi ;;
      *) keep+=("$path") ;;
    esac
  done
  remove=(${keep[@]+"${keep[@]}"})
fi

# Every move and removal must be possible before the first one happens.
for path in ${remove[@]+"${remove[@]}"} ${aside[@]+"${aside[@]}"}; do
  parent="$(dirname "$path")"
  if [[ ! -w "$parent" || ! -x "$parent" ]]; then
    echo "uninstall.sh: $parent is not writable, so $path cannot be removed or moved aside; nothing was changed" >&2
    exit 1
  fi
done

# ---- act ----
# The moves first: they are the step that can still be undone whole, so a
# failure there leaves nothing switched off either.
moved_from=()
moved_to=()
for path in ${aside[@]+"${aside[@]}"}; do
  if dest="$(oskar_cmd record aside "$path" uninstalled)"; then
    moved_from+=("$path")
    moved_to+=("$dest")
    continue
  fi
  echo "uninstall.sh: could not move $path aside" >&2
  for ((i = ${#moved_from[@]} - 1; i >= 0; i--)); do
    if mv -T -n -- "${moved_to[i]}" "${moved_from[i]}" \
        && present "${moved_from[i]}" && ! present "${moved_to[i]}"; then
      echo "uninstall.sh: moved ${moved_from[i]} back" >&2
    else
      echo "uninstall.sh: could NOT move ${moved_to[i]} back to ${moved_from[i]}; it is still at ${moved_to[i]}" >&2
    fi
  done
  echo "uninstall.sh: nothing was removed or switched off" >&2
  exit 1
done

if [[ "$(readlink -f "$reg" 2>/dev/null || true)" == "$(readlink -f "$here")" ]]; then
  oskar_cmd teardown
else
  echo "uninstall.sh: registration does not point at this checkout; leaving the live install alone" >&2
fi

removed=()
for path in ${remove[@]+"${remove[@]}"}; do
  if ours "$path" && rm -f -- "$path"; then
    removed+=("$path")
  elif present "$path"; then
    unmatched+=("$path")
  fi
done

gone=(${removed[@]+"${removed[@]}"} ${moved_from[@]+"${moved_from[@]}"})
if ((${#gone[@]})); then
  oskar_cmd record forget "${gone[@]}" \
    || echo "uninstall.sh: the install record could not be updated" >&2
fi
unit_gone=""
for path in ${gone[@]+"${gone[@]}"}; do
  if [[ "$path" == "$unit" ]]; then unit_gone=1; fi
done
if [[ -n "$unit_gone" ]] && ! present "$unit"; then
  # The unit file this run removed or moved aside leaves its enablement
  # links pointing at nothing. Only links whose text is exactly that
  # path go; `systemctl disable` would act by name and also drop another
  # program's oskar.service enablement.
  oskar_cmd unlink-enablement >&2 || true
fi
systemctl --user daemon-reload

# ---- say what is true ----
for path in ${removed[@]+"${removed[@]}"}; do echo "uninstall.sh: removed $path" >&2; done
for i in "${!moved_from[@]}"; do
  echo "uninstall.sh: --force: ${moved_from[i]} did not match OSKar's install record; moved aside as ${moved_to[i]}" >&2
done
if ((${#unmatched[@]})) || [[ -n "$held" ]]; then
  echo "uninstall.sh: these stay:" >&2
  for path in ${unmatched[@]+"${unmatched[@]}"}; do
    echo "  $path (does not match what OSKar installed)" >&2
  done
  if [[ -n "$held" ]]; then
    echo "  $binary (OSKar's, kept because $unit was changed since OSKar installed it and still runs it)" >&2
    [[ -z "$held_cli" ]] || echo "  $cli (OSKar's, kept so that uninstall.sh can finish from this checkout)" >&2
    echo "To finish: undo your change to $unit or remove it yourself, then run uninstall.sh again; or run uninstall.sh --force, which moves the changed unit aside (deleting nothing) and removes the rest." >&2
  fi
fi
if present "$reg" && [[ "$(readlink -f "$reg" 2>/dev/null || true)" != "$(readlink -f "$here")" ]]; then
  echo "uninstall.sh: note — the registration at $(readlink -f "$reg" 2>/dev/null || echo "$reg") relied on the shared unit just removed; that checkout must run its own install again before the next reboot or its service will be absent" >&2
fi
state_line
if ((${#unmatched[@]})) || [[ -n "$held" ]]; then
  echo "Source install partly removed: the files above stay. Config and state preserved."
else
  echo "Source install removed. Config and state preserved."
fi
