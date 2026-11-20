# On the exit node: DNS to any address is answered by Tor, and when Tor stops,
# lookups fail instead of falling back to plain DNS.
# Regenerate from the repo root on the KVM host:  vhs docs/demo/fail-closed.tape
# (briefly stops the Tor container on the deployed VM)
Output docs/demo/fail-closed.gif

Require make
Require ssh

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 15
Set Width 1240
Set Height 470
Set Padding 26
Set Margin 30
Set MarginFill "#59316B"
Set BorderRadius 12
Set WindowBar Colorful
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set Framerate 24

# Log in off-camera so the login banner stays out of the recording.
Hide
Type "make ssh"
Sleep 300ms
Enter
# VHS does not see the prompt after the login banner scrolls, so just wait.
Sleep 8s
Type "clear"
Enter
Sleep 800ms
Show

Sleep 600ms

Type "curl -sw '\n' -x socks5h://localhost:9050 https://check.torproject.org/api/ip"
Enter
Wait+Screen@60s /IsTor/
Sleep 2s

Type "# nothing listens on 192.0.2.53, so only Tor can answer"
Enter
Type "dig +short @192.0.2.53 torproject.org"
Enter
Wait@30s /~\$$/
Sleep 2.5s

Type "sudo docker stop tor-proxy"
Enter
Wait@60s /~\$$/
Sleep 800ms
Type "dig +short +tries=1 @192.0.2.53 torproject.org   # Tor down: no fallback"
Enter
Wait+Screen@30s /timed out|no servers/
Sleep 3.5s

Type "sudo docker start tor-proxy   # back to normal"
Enter
Sleep 2.5s

Hide
Type "exit"
Enter
Sleep 1s
