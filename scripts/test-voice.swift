import AppKit
import AVFoundation
import Speech

@main struct VoiceChecks {
    static func main() {
        let voice=CompanionVoice();var states:[String]=[]
        voice.onState={id,phase in states.append(id + ":" + phase)};voice.cancel();voice.cancel()
        voice.start(captureID: "")
        precondition(states.isEmpty,"idle cancellation and invalid capture IDs must not request access or overwrite a draft")
        precondition(!voice.active)
        let authorization=SFSpeechRecognizer.authorizationStatus()
        guard let selected=CompanionVoice.preferredVoice() else{fatalError("No installed voice")}
        print("Selected voice: \(selected.name), \(selected.language), quality \(selected.quality.rawValue)")
        if CommandLine.arguments.count<2{print("PASS idle voice state and installed voice selection");return}
        let url=URL(fileURLWithPath:CommandLine.arguments[1]),synth=AVSpeechSynthesizer(),utterance=AVSpeechUtterance(string:"I can point, circle, and highlight. Your mouse stays yours.")
        utterance.voice=selected;utterance.rate=AVSpeechUtteranceDefaultSpeechRate
        let lock=NSLock();var file:AVAudioFile?,frames:AVAudioFramePosition=0,finished=false
        synth.write(utterance){buffer in
            guard let pcm=buffer as? AVAudioPCMBuffer else{return}
            lock.lock();defer{lock.unlock()}
            if finished{return}
            if pcm.frameLength==0{
                finished=true
                precondition(frames>0,"speech synthesis produces audio")
                DispatchQueue.main.async{
                    precondition(SFSpeechRecognizer.authorizationStatus()==authorization,"preview must not request microphone or recognition access")
                    print("PASS voice preview: \(frames) audio frames; no microphone capture")
                    CFRunLoopStop(CFRunLoopGetMain())
                };return
            }
            do{if file==nil{file=try AVAudioFile(forWriting:url,settings:pcm.format.settings)};try file?.write(from:pcm);frames+=AVAudioFramePosition(pcm.frameLength)}catch{fputs("Voice output failed: \(error)\n",stderr);exit(1)}
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+25){if !finished{fputs("Voice preview timed out\n",stderr);exit(1)}}
        withExtendedLifetime(synth){CFRunLoopRun()}
    }
}
