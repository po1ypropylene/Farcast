# RDP performance questions

## What the code review established

The recent full-screen return fix made mailbox notifications invoke the Metal
delegate directly and release drawable resources before and after every frame.
Notifications coalesced only until the main thread handled them; a continuous
producer could still trigger uploads faster than the display refresh rate.
The shared texture also had no explicit CPU/GPU ownership boundary.

The revised renderer paces mailbox-driven uploads to the destination screen's
maximum refresh rate, keeps one scheduled redraw and one GPU command buffer per
surface, and reads the newest mailbox frame when rendering can proceed. MTKView
owns each explicit draw's drawable lifecycle; window transfers release cached
drawables. The renderer is shared by RDP and VNC.

These are local scheduling/resource fixes. They do not establish the cause of the
reported production slowdown or prove an improvement to remote desktop FPS.

## User-confirmed outcome

The user reports that build 33 restored the previous behavior. The regression
started immediately on all tested transport types, with scrolling/animation,
keyboard/mouse response and cursor motion affected while the rest of Farcast
remained responsive. The reported setup is Windows Server 2022, a 60 Hz host
display and approximately 1440 × 900 without Retina or full screen. The build from
two days earlier was smooth. This supports a shared-renderer regression; it does
not isolate which rendering change was responsible or measure end-to-end latency.

The original answers below are retained. Remaining measurement and transport
questions are separate from the reported slowdown, which the user considers fixed.
See [follow-up assessment](../REVIEW_FINDINGS.md#rdp-performance-follow-up-assessment)
for the technical recommendations and their evidence limits.

## Original questions and user answers

1. Does lag start immediately after connecting, or only after pop-out/full-screen
   use, resizing, switching tabs or a long connection? Which transition first
   makes it noticeably worse?
   
   Immediately
   
2. Does it affect direct RDP, WireGuard, OpenVPN or all of them? Does another RDP
   client remain smooth against the same server using the same network path?
   
   All of them
   
3. What remote resolution, Retina setting and Resize with window setting reproduce
   it? Does disabling Retina or using a smaller desktop materially improve it?
   The recent startup change applies the actual viewport when resizing is enabled;
   a larger negotiated desktop increases bitmap decode/copy/upload work.
   
   Did not use full screen or Retina. It's approximately 1440x900.
   
4. Is the problem scrolling/window animation, delayed keyboard/mouse responses,
   cursor motion, or all three? Does the rest of Farcast stay responsive?
   
   All of them. The rest of Farcast is responsive.
   
5. What server implementation/version and host display refresh rate are involved?
   What is the last known smooth Farcast version/build?
   
   60Hz and Windows Server 2022. The build from two days ago was smooth.
   
6. After trying this build, which symptoms remain, and does reconnecting clear them?

Basically, after this build, it has improved and behaves like before.

## Remaining technical uncertainties

- The protected live-server probe could not validate the supplied configuration:
  it reported invalid entries or missing SSH fingerprints. This is a test-input
  blocker, not an RDP performance failure. Independently verified pins and valid
  enabled entries must be supplied locally before that probe can provide evidence;
  do not send credentials or fingerprints in answers to this document.
- End-to-end production frame rate and input latency have not been measured.
  The owned 4K fixture isolates renderer publication/upload overhead; it does not
  include RDP decode or network traffic. It prints window occlusion explicitly:
  an occluded run does not prove GPU presentation timing or displayed FPS.
- The native adapter still snapshots the full decoded desktop at EndPaint.
  Dirty-region transport could reduce copying, but requires a coherent accumulated
  image across dropped frames, resized desktops and multiple presentation surfaces.
  A production profile is needed to justify that larger change.
- Graphics pipeline/H.264 negotiation remains disabled because an earlier server
  authenticated without starting its negotiated GFX channel. Re-enabling it needs
  evidence from the affected server and a compatible fallback strategy.
- A silent remote-path stall through a VPN can remain distinct from presentation
  overhead; local worker progress alone does not establish remote-path liveness.

Please answer with settings and observations only; omit credentials, server
addresses, remote desktop contents and original crash logs.
