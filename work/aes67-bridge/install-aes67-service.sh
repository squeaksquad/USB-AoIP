#!/bin/bash
# Install usb16x16-aes67.service on the Pi. Run once with sudo from the
# staging directory that holds the supervisor, the unit and aes67.conf.
# Verifies every staged file against its pinned hash and the installed
# bridge against the accepted binary, installs, reloads systemd. Does not
# enable or start the service.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
supervisor_source="$script_dir/usb16x16-aes67-supervisor"
unit_source="$script_dir/usb16x16-aes67.service"
conf_source="$script_dir/aes67.conf"
supervisor_destination=/usr/local/sbin/usb16x16-aes67-supervisor
unit_destination=/etc/systemd/system/usb16x16-aes67.service
conf_destination=/etc/usb16x16/aes67.conf
sudoers_destination=/etc/sudoers.d/usb16x16-aes67
bridge_binary=/usr/local/libexec/usb16x16-rt-bridge
expected_supervisor_sha256=892dd18942a4fd05e985ba7ff4e29906c83e68b1c8a41e2fa527d877edab5dfc
expected_unit_sha256=77837e60e7a0660ce9d0c31c8077363805c118df6bdcdba9619417669eccd702
expected_conf_sha256=3cda845dbb2f5b926f33ffee6e38543fc227f192a30a0e39a76b8112600b0825
expected_bridge_sha256=c1ca48c544b9c6fe0fccf03a438bf73ac7e9f616dd44127a11718a8bba529323

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

for source in "$supervisor_source" "$unit_source" "$conf_source"; do
  if [ ! -r "$source" ]; then
    echo "missing staged file: $source" >&2
    exit 3
  fi
done
if [ "$(sha256_of "$supervisor_source")" != "$expected_supervisor_sha256" ]; then
  echo "supervisor source hash mismatch" >&2
  exit 4
fi
if [ "$(sha256_of "$unit_source")" != "$expected_unit_sha256" ]; then
  echo "unit source hash mismatch" >&2
  exit 5
fi
if [ "$(sha256_of "$conf_source")" != "$expected_conf_sha256" ]; then
  echo "aes67.conf source hash mismatch" >&2
  exit 6
fi
if [ "$(sha256_of "$bridge_binary")" != "$expected_bridge_sha256" ] ||
   [ "$(stat -c '%U:%G:%a' "$bridge_binary")" != root:root:755 ]; then
  echo "installed bridge is not the accepted binary; install it with install-candidate.sh first" >&2
  exit 7
fi
bash -n "$supervisor_source"
if [ "$(systemctl is-active usb16x16-aes67.service 2>/dev/null)" = active ]; then
  echo "usb16x16-aes67.service is active; stop it before reinstalling" >&2
  exit 8
fi

sudoers_temporary=$(mktemp /tmp/usb16x16-aes67-sudoers.XXXXXX)
trap 'rm -f "$sudoers_temporary"' EXIT HUP INT TERM
cat > "$sudoers_temporary" <<'EOF'
# Password-free operation of the AES67 service and the acceptance tests.
bdimaio ALL=(root) NOPASSWD: /usr/bin/systemctl start usb16x16-aes67, \
    /usr/bin/systemctl stop usb16x16-aes67, \
    /usr/bin/systemctl restart usb16x16-aes67, \
    /usr/bin/systemctl enable usb16x16-aes67, \
    /usr/bin/systemctl disable usb16x16-aes67, \
    /usr/bin/systemctl disable --now usb16x16-aes67, \
    /usr/local/sbin/usb16x16-aes67-supervisor switch-profile *, \
    /usr/local/sbin/usb16x16-aes67-supervisor cleanup, \
    /usr/bin/pkill -9 -x aes67-daemon, \
    /usr/bin/pkill -9 -f ^/usr/local/libexec/usb16x16-rt-bridge, \
    /usr/sbin/reboot
EOF
/usr/sbin/visudo -cf "$sudoers_temporary"

install -d -o root -g root -m 755 /etc/usb16x16
install -o root -g root -m 755 "$supervisor_source" "$supervisor_destination"
install -o root -g root -m 644 "$unit_source" "$unit_destination"
if [ ! -e "$conf_destination" ]; then
  install -o root -g root -m 644 "$conf_source" "$conf_destination"
  echo "installed $conf_destination"
elif [ "$(sha256_of "$conf_destination")" = "$expected_conf_sha256" ]; then
  echo "unchanged $conf_destination"
elif grep -qx "$(sha256_of "$conf_destination")" <<'PREVIOUS'
61a72df14d612e800a45a4dd0b21200a73a39a83e59556cca722348e2b2a8612
a039a3cccc2e9d0d02cd77424384b6406fe7303af5fe3ceac22b94f8e49941ae
f2e1531f2aa8c43de66cb219319d612e2e2dfea1af40c9775dbabd005d1e8db8
4bd2f07069832fdc37bd935097f448db84f7b240fd4442f12a30ab9be7f6b820
46995a455309001be04a98ccd61491b39c6f89894e462edb3868a5ad21018137
a811f5c375aaed1993fcdd4ad181898a58f6123081bc0b838a27ba974c91acde
ba3c7a98ecb32bb471b0c2a4e9d584172cfce0c8a1cefc044c8e703a5f130c89
52591f6f5834586e1cfb171f7820df62d9ee1f091a546efd334507ae643b0002
e662755ba2a9bbbbf7a1164b0e9f54620e10894cac0aa1beaf50f1c560707cb6
14d74d921dc2aa9016243fc3a81dfba6aae90a7dffac52926ca23f24acb7622e
7c08af39c1cf98c0e3783d59e03b21a24c4f1af6f9f3def2ac59515e85e175c1
404967303a7f9d73d89c7e7b9884431de33e846f48bc0b6c52dc6f884b9281cb
59a23d5e42d14896dc33c964983a69a39d5f78d3db8cd5458294e635969b7721
2029ef8f8c39fc5cf4fdf8e886cc04cd0930e6dfcc50905e964552e38534192d
ea9158abf01e0ecd1e98afe2811aca106e9f379823d70cd77ec44e176487db3e
81e8c092ac33c68ac67c261b5c88c3033fd959400eddeac987e98b2a00f48f97
2fa48cb691e15fa330c1a3a0292d19a577ba60244821354e2eaa11899799bedf
e6f913649d47e68eec4c08a93814ee49a5e5f1328c9596de4676de6cd5485498
85ccc0fef79c39fff7a04639ed3c2118400803933a8608fd83721298e726fc8a
7f50108c82153742d991323f897fd0e52f73a40fbe4fa5544b7bfb7a16c86133
a706a0c253c9fb835c5794b154d838cda67b45fa908723bfd6da7a516c72b5ef
46fd274f7b2fcabaf07954f2e06db525c80d3f3f163961fc849e12d196ffe717
82614fdf3e5a8f93f97c394f0048c33085a0cfa7ed5918c10da43755d356ff3f
848cc08def14f304d1a229bf431dcd0345fb22c3317f7d178f7efe10ed22168f
ec4b587b1e87457190f787ef71db419f9b763e55fb155baf1ae58bc25c62ffe8
d26487905282303bc25893656a80f2da9fbc3aa37c93639207a13388971f3968
bc674a2967a490a19568db89de2f9ef9e0b3e208966150334c03a76ef7a20a21
f4ba358fd02545bad6a9d532d89e88f2db6362e1a28f947d3b8ed7f727a29dc6
196786be35121efafd9fd94ff5ac10a2e613f7dfa22ffbe90ab6cf6438407665
ed23c829ff1287f5e7628d8b1e8074a2f5880a18aaf904e3356e2b15b4f274f3
1099fbe1a152e0725d15dc35485555bde656d015afcb7f0c34c00cccb9e6e78f
6ce387f4719ac9065573a4affa5991ede8e9c56d2d57910794dda3ca05ea725a
1ae47899aba0f44c258b5f078d7719048537231022554290acd568992b92ca64
705c7906899f64d2a1d90fbddcbfd60c3e8d4d9e85b699debbca443c5073502f
3f087d4123aebcbb51186ad21d3934643bd6ec151e9e003313f8c7fbc2c0d62f
db094139bb8141d1d478ed7c41e980271abcb397664d7ffec325ac157b157069
c7092ea1aebd8a40dad831c12819101eaa7a72108f872002c5538fa7b3149e58
e8ae5e69c00df7f58b78578e586a7d23e9d6ffefb2dfcc464d755803277b650f
b74b933066ad547eaa4757fe9e419ab7676ec8439c6deb281722dcf3cf0a9b31
c9cce44542d6a0deefce575d9852e21472710876ba903fb51ad32df09a8759bf
52e82dcb88bed048ba277b8c10523f39d5b68c6cea8dada7b2b4c3bb3a1ffcc1
d6f463a6f6cd6678c595506780f370f7b09fc0e0144a6dad16005f15b0518426
5a2de43b5d4b5770c958657b534e4aad546e8ff5efbee8b47172ad95e0d020d9
9428db88fb62199929a44b3462081993e1891be07147ba227d7dd64511932f61
dc3fa09752e7bc7aaffc93ba87815dfe7ac47f704ce7ee934374d57b5e705df4
0ae3617b9f863ec50973e5b9d310b694fcf6195143f7d79bf2cdcc990ae0e566
fb6739aa57f6b4fc2d564ca91f434a1284b49e6bf5ba5651559117afbb648f83
101c41ec4f06a3af853b60f16ed220d075fae696b76f5433ce4f515f7ecd1091
98b467ea8ad6012fe01f9d8e18625cf6b0c74fcf2aa73913f4b5db51dad090a8
3fb76a98ce0d7e30672862237a80a8f1128bc980aa69c5b28709d3e61ffee38f
PREVIOUS
then
  # an unedited copy of a previously shipped version: replace it
  install -o root -g root -m 644 "$conf_source" "$conf_destination"
  echo "updated $conf_destination (was the shipped version, unedited)"
else
  install -o root -g root -m 644 "$conf_source" "$conf_destination.new"
  echo "kept operator-edited $conf_destination; shipped version is at $conf_destination.new"
fi
install -o root -g root -m 440 "$sudoers_temporary" "$sudoers_destination"
/usr/sbin/visudo -cf "$sudoers_destination"
systemctl daemon-reload

echo "installed $supervisor_destination"
echo "installed $unit_destination"
echo "installed $sudoers_destination"
echo "not enabled, not started. Next: sudo systemctl start usb16x16-aes67; usb16x16-aes67-supervisor status"
