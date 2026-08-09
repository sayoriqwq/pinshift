import ControllerCLI

@main
struct PinshiftControllerMain {
  static func main() async {
    await PinshiftControllerCommand.main()
  }
}
