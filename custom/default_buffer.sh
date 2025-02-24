temp_file=$(mktemp /tmp/tmux-buffer-default.XXXXXX)
# if [ $? -ne 0 ]; then
#   echo "Failed to create temporary file"
#   exit 1
# fi
# echo "Temp file created: $temp_file"

# Save the tmux buffer content to the temporary file
tmux show-buffer > "$temp_file"
# if [ $? -ne 0 ]; then
#   echo "Failed to save buffer content to temporary file"
#   rm "$temp_file"
#   exit 1
# fi
# echo "Buffer content saved to temp file"

# Open the temporary file with nvim in a new tmux window
# $EDITOR env var in tmux.conf.local
tmux new-window -n 'nvim-edit' "$EDITOR $temp_file; rm $temp_file"
tmux display-message "nvim opened in new window. Edit and close nvim to delete the temp file."
# 
# Notify the user that the script has executed if in tmux
# if [ -n "$TMUX" ]; then
#   tmux display "nvim opened in new window. Edit and close nvim to delete the temp file."
# else
#   echo "nvim opened. Edit and close nvim to delete the temp file."
# fi

