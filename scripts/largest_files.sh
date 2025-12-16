# Usage: ./largest-files.sh /path/to/dir [NUM]
# Default NUM = 20

DIR="${1:-.}"
NUM="${2:-20}"

if [[ ! -d "$DIR" ]]; then
    echo "Errore: directory non valida: $DIR" >&2
    exit 1
fi

echo "Elenco dei $NUM file più grandi in: $DIR"
echo "------------------------------------------------------------"

find "$DIR" -type f -print0 \
  | xargs -0 du -b 2>/dev/null \
  | sort -nr \
  | head -n "$NUM" \
  | awk '{ printf "%10s  %s\n", $1, $2 }'
