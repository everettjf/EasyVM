import EasyVMCLIKit
import Foundation

let cli = EasyVMCLI()
let (exitCode, response) = cli.run(arguments: Array(CommandLine.arguments.dropFirst()))
do {
    FileHandle.standardOutput.write(try cli.encode(response))
} catch {
    FileHandle.standardError.write(Data("easyvm: could not encode response: \(error)\n".utf8))
    exit(EasyVMCLIExit.internalError.rawValue)
}
exit(exitCode.rawValue)
