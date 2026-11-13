#!/usr/bin/env bash
# Copy the installer and the built os-switch into the VM and run the installer
# there, answering: continue, no hibernation setup, no Secure Boot, os-switch yes.
set -euo pipefail
cd "$(dirname "$0")/../.."
VM=tests/vm/vm.sh
cargo build --release -q
$VM ssh 'rm -rf ~/osw && mkdir ~/osw'
tar -c install.sh install -C target/release os-switch | $VM ssh 'tar -x -C ~/osw'
printf 'y\nn\nn\ny\nn\nn\nn\n' | $VM ssh 'cd ~/osw && ./install.sh'
