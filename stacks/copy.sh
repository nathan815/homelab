HOST=$1

SCRIPT_DIR=$(dirname "$0")

cd $SCRIPT_DIR/..

sh ./stacks/validate.sh

echo ""
echo "Copying stacks folder to $HOST..."

rsync -r stacks/ $HOST:/opt/stacks
