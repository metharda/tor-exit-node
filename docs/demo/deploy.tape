# A fresh deployment, played back 10x faster than real time.
# Record on the KVM host from a checkout with no VM deployed. Export
# VM_PASSWORD and TS_AUTHKEY first so no secret is typed on camera:
#   vhs docs/demo/deploy.tape
Output docs/demo/deploy.gif

Require make

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 15
Set Width 1240
Set Height 620
Set Padding 26
Set Margin 30
Set MarginFill "#59316B"
Set BorderRadius 12
Set WindowBar Colorful
Set Theme "Catppuccin Mocha"
Set Framerate 20
Set PlaybackSpeed 10
# Recording runs in real time; playback is 10x, so these read as ~50ms/key.
Set TypingSpeed 500ms

Hide
Type "export PS1='tor-exit-node $ ' && clear"
Enter
Sleep 2s
Show

Sleep 5s
Type "make deploy"
Sleep 3s
Enter

Wait@120s /VM name/
Sleep 8s
Type "tor-exit-demo"
Sleep 3s
Enter
Wait@30s /VM user/
Sleep 5s
Enter
Wait@30s /Memory/
Sleep 4s
Enter
Wait@30s /vCPUs/
Sleep 4s
Enter
Wait@30s /Disk/
Sleep 4s
Enter

Wait@40m /node \$$/
Sleep 60s
