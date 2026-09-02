//
//  VMModelFieldAudioDevice.swift
//  EZVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

#if arch(arm64)
struct VMModelFieldAudioDevice: Decodable, Encodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case InputOutputStream, InputStream, OutputStream
        var id: Self { self }

        var displayName: String {
            switch self {
            case .InputOutputStream: "Microphone & Speakers"
            case .InputStream: "Microphone"
            case .OutputStream: "Speakers"
            }
        }

        var systemImage: String {
            switch self {
            case .InputOutputStream: "waveform"
            case .InputStream: "mic"
            case .OutputStream: "speaker.wave.2"
            }
        }
    }
    let type: DeviceType
    
    var description: String {
        return type.displayName
    }
    
    static func `default`() -> VMModelFieldAudioDevice {
        return VMModelFieldAudioDevice(type:.InputOutputStream)
    }
    
    func createConfiguration() -> VZAudioDeviceConfiguration {
        if type == .InputStream {
            let audioConfiguration = VZVirtioSoundDeviceConfiguration()
            let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
            inputStream.source = VZHostAudioInputStreamSource()
            audioConfiguration.streams = [inputStream]
            return audioConfiguration
        }
        
        if type == .OutputStream {
            let audioConfiguration = VZVirtioSoundDeviceConfiguration()
            let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
            outputStream.sink = VZHostAudioOutputStreamSink()
            audioConfiguration.streams = [outputStream]
            return audioConfiguration
        }
        
        let audioConfiguration = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        audioConfiguration.streams = [inputStream, outputStream]
        return audioConfiguration
    }
}

#endif
