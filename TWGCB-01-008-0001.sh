# 0) Backup the file
cp -a TWGCB-01-008-0001.sh TWGCB-01-008-0001.sh.bak

# 1) Inspect the first 12 lines (with "Line: " in front) to confirm the // lines
nl -ba -w1 -s': ' TWGCB-01-008-0001.sh | sed -n '1,12p' | sed 's/^\s*\([0-9]\+\): /Line: \1:/'

# 2) Convert any leading '//' at the top back to '#'
#    (adjust 1,15 if needed; this just covers the header area)
sed -i '1,15s|^//|#|' TWGCB-01-008-0001.sh

# 3) Ensure Unix line endings (in case the file picked up CRLFs)
sed -i 's/\r$//' TWGCB-01-008-0001.sh
