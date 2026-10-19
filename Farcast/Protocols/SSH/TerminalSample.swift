/// Self-contained fictional output for the terminal appearance preview.
enum TerminalSample {
    static let prompt = "barry@star-labs:~$ "
    static let text = """
        S.T.A.R. LABS
        Scientific and Technological Advanced Research Laboratories

        \(prompt)gideon status

          \u{1B}[32mGideon is online. All systems are operational.\u{1B}[0m

          Service                 Status      Last update
          Cortex telemetry        running     2 minutes ago
          Speed Force monitor     stable      12 seconds ago
          Particle accelerator    standby     1 hour ago
          Central City sensors    connected   just now

        \(prompt)ls research
        \u{1B}[34mfield-reports  telemetry  archives\u{1B}[0m

        \(prompt)
        """
}
