import EZVMCLIKit
import Foundation

let cli = EZVMCLI()
let (exitCode, response) = cli.run(arguments: Array(CommandLine.arguments.dropFirst()))
do {
    FileHandle.standardOutput.write(try cli.encode(response))
} catch {
    FileHandle.standardError.write(Data("ezvm: could not encode response: \(error)\n".utf8))
    exit(EZVMCLIExit.internalError.rawValue)
}
exit(exitCode.rawValue)
