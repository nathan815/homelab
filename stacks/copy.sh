SCRIPT_DIR=$(dirname "$0")

cd $SCRIPT_DIR/..

sh ./stacks/validate.sh

echo ""
echo "Copying stacks folder to pi01.lan..."

rsync -r stacks pi01.lan:/opt/homelab
