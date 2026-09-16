#!/bin/bash
# The plugin sets itself up the first time the shell loads it (see `setup`
# in send.sh): the Nautilus menu item is copied into place and, once, a
# notification offers to add the SUPER+SHIFT+T keybind. This script exists
# for running that by hand, and for taking the Nautilus item out again:
#
#   install.sh            run setup now
#   install.sh --remove   remove the Nautilus menu item

set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$here/send.sh" setup "$@"
