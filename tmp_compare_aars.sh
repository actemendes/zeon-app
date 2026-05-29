set -euo pipefail
cd /mnt/b/1CODING/zeon-app/android/app/libs
ls -lh hiddify-core.aar hiddify-core.aar.bak_20260529_1718
for f in hiddify-core.aar hiddify-core.aar.bak_20260529_1718; do
  echo "===== $f: file type ====="
  file "$f"
  echo "===== $f: zip test ====="
  unzip -t "$f" >/tmp/${f}.test.txt || true
  tail -n 5 /tmp/${f}.test.txt
  echo "===== $f: top entries ====="
  unzip -Z1 "$f" | head -n 20
  echo "===== $f: contains classes.jar? ====="
  unzip -Z1 "$f" | grep -n classes.jar || true
  echo
 done
 echo "===== Diff entry names ====="
 diff -u <(unzip -Z1 hiddify-core.aar | sort) <(unzip -Z1 hiddify-core.aar.bak_20260529_1718 | sort) | sed -n '1,200p'