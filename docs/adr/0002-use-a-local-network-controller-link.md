# Use a local-network controller link

The Pinshift app and Mac Simulation Controller discover each other with Bonjour and exchange Status, Apply and Clear over paired TLS. Apple-supported local networking avoids coupling control messages to USB forwarding; the separate Xcode device connection serves the devicectl Injection Backend.
