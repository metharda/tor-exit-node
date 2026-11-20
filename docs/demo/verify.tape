# Health and leak check against a deployed exit node.
# Regenerate from the repo root on the KVM host:  vhs docs/demo/verify.tape
Output docs/demo/verify.gif

Require make
Require ssh

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
Set TypingSpeed 55ms
Set Framerate 24

Hide
Type "export PS1='tor-exit-node $ ' && clear"
Enter
Sleep 500ms
Show

Sleep 600ms
Type "make verify"
Sleep 500ms
Enter
Wait+Screen@180s /All checks passed/
Sleep 5s
