old=$(tmux show -w synchronize-panes)
new=""

if [ "$old" = "synchronize-panes on" ]; then
  new="off"
else
  new="on"
fi

tmux set-window-option synchronize-panes $new
