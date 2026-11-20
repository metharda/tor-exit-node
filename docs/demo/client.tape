# A tailnet device switching to the exit node and back.
# Record on any tailnet device with the tailscale CLI, curl and jq:
#   vhs docs/demo/client.tape
# (the demo hides the device's real IP by printing only IsTor before switching)
Output docs/demo/client.gif

Require tailscale
Require curl
Require jq

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 15
Set Width 1240
Set Height 420
Set Padding 26
Set Margin 30
Set MarginFill "#59316B"
Set BorderRadius 12
Set WindowBar Colorful
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set Framerate 24

Hide
Type "tailscale set --exit-node= ; export PS1='laptop $ ' && clear"
Enter
Sleep 2s
Show

Sleep 600ms
Type "curl -s https://check.torproject.org/api/ip | jq .IsTor   # normal internet"
Enter
Wait@30s /laptop \$$/
Sleep 1.5s

Type "tailscale set --exit-node=tailscale-tor-exit"
Enter
Wait@30s /laptop \$$/
Sleep 1s

Type "curl -sw '\n' https://check.torproject.org/api/ip"
Sleep 300ms
Enter
Wait+Screen@90s /"IsTor":true/
Sleep 1.5s

Type "curl -s https://icanhazip.com   # what every site sees: a Tor exit"
Enter
Wait@90s /laptop \$$/
Sleep 2s

Type "tailscale set --exit-node=   # switch back"
Enter
Wait@30s /laptop \$$/
Type "curl -s https://check.torproject.org/api/ip | jq .IsTor"
Enter
Wait@30s /laptop \$$/
Sleep 3s
