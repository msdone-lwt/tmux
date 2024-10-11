# Base on oh-my-tmux

- tmux.conf 不是一个软连接，而是一个本地文件，如果需要可以下载 oh-my-tmux,并将 tmux.conf 软链到本目录下的 tmux.conf

## set tmux-256color

```shell
curl -LO https://invisible-island.net/datafiles/current/terminfo.src.gz && gunzip terminfo.src.gz

/usr/bin/tic -xe tmux-256color terminfo.src

If you want to use tmux-256color for all users, use sudo. The result is placed into /usr/share/terminfo:
sudo /usr/bin/tic -xe tmux-256color terminfo.src
```
