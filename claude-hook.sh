#!/bin/sh
# Oh My Notch! — hook do Claude Code: anexa o evento (JSON da entrada padrão) ao arquivo que o app acompanha.
# Não imprime nada e termina rápido.
DIR="$HOME/.ohmynotch"
mkdir -p "$DIR"
{ cat; printf '\036\n'; } >> "$DIR/claude-events.log" 2>/dev/null
exit 0
