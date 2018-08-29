//
//  ViewController.swift
//  tone generator
//
//  Created by Yoshua Elmaryono on 28/08/18.
//  Copyright © 2018 Yoshua Elmaryono. All rights reserved.
//

import UIKit

class ViewController: UIViewController {
    private var unit: ToneOutputUnit! = ToneOutputUnit()
    private weak var toneSlider: UISlider!
    private weak var frequencyLabel: UILabel!
    private var toneFrequency: Float = 0.0 {
        didSet {
            frequencyLabel.text = "\(toneFrequency) Hz"
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        setupSlider()
        setupPlayButton()
        setupLabel()
    }
    override func viewWillAppear(_ animated: Bool) {
        toneFrequency = 440
        toneSlider.value = toneFrequency
    }
    
    private func setupLabel(){
        let label = UILabel()
        label.textAlignment = .center
        view.addSubview(label)
        
        label.translatesAutoresizingMaskIntoConstraints = false
        label.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 0).isActive = true
        label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80).isActive = true
        label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.9).isActive = true
        
        frequencyLabel = label
    }
    private func setupSlider(){
        let slider = UISlider()
        slider.minimumValue = 65
        slider.maximumValue = 1320
        slider.addTarget(self, action: #selector(changeFrequency), for: .valueChanged)
        view.addSubview(slider)
        
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 0).isActive = true
        slider.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -50).isActive = true
        slider.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.9).isActive = true
        
        toneSlider = slider
    }
    
    private func setupPlayButton(){
        let button = UIButton()
        button.backgroundColor = .blue
        button.setTitle("Play Sound", for: .normal)
        button.setTitle("Stop", for: .highlighted)
        button.addTarget(self, action: #selector(playTone), for: .touchDown)
        button.addTarget(self, action: #selector(stopTone), for: .touchUpInside)
        view.addSubview(button)
        
        button.translatesAutoresizingMaskIntoConstraints = false
        button.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 0).isActive = true
        button.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 0).isActive = true
        button.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.6).isActive = true
    }
    
    @objc func changeFrequency(_ sender: UISlider){
        toneFrequency = sender.value
    }
    @objc func stopTone(_ sender: UIButton){
        sender.backgroundColor = .blue
        unit.stop()
    }
    @objc func playTone(_ sender: UIButton){
        sender.backgroundColor = .gray
        
        unit.enableSpeaker()
        unit.toneCount=64000
        unit.setFrequency(frequency: Double(toneFrequency))
        unit.setToneVolume(volume: 0.5)
        unit.startToneForDuration(time: 10)
    }
}

import Foundation
import AudioUnit
import AVFoundation

final class ToneOutputUnit: NSObject {
    private var audioUnit: AUAudioUnit! = nil
    private var audioUnit_isRunning = false
    private var audioSession_isActive = false
    
    var toneCount: Int32 = 0            // number of samples of tone to play.  0 for silence
    
    private var sampleRate : Double = 44100.0    // typical audio sample rate
    private var f0 = 880.0              // default frequency of tone:   'A' above Concert A
    private var v0 = 16383.0            // default volume of tone:      half full scale
    private var phY =     0.0           // save phase of sine wave to prevent clicking
    private var interrupted = false     // for restart from audio interruption notification
    
    func startToneForDuration(time : Double) {
        if !audioUnit_isRunning { enableSpeaker() }
        if toneCount == 0 {         // only play a tone if the last tone has stopped
            toneCount = Int32(time * sampleRate)
        }
    }
    
    func setFrequency(frequency: Double) {
        f0 = frequency
    }
    func setToneVolume(volume: Double) {  // 0.0 to 1.0
        v0 = volume * 32766.0
    }
    func setToneTime(time: Double) {
        toneCount = Int32(time * sampleRate);
    }
    
    func enableSpeaker() {
        if audioUnit_isRunning { return }           // return if RemoteIO is already running
        
        if (!audioSession_isActive) {
            setAndActivate_audioSession()
        }
        
        do {
            if (audioUnit == nil) { // not running, so start hardware
                let audioComponentDescription = AudioComponentDescription(
                    componentType: kAudioUnitType_Output,
                    componentSubType: kAudioUnitSubType_RemoteIO,
                    componentManufacturer: kAudioUnitManufacturer_Apple,
                    componentFlags: 0,
                    componentFlagsMask: 0
                )
                try audioUnit = AUAudioUnit(componentDescription: audioComponentDescription)
                let bus0 = audioUnit.inputBusses[0]
                let audioFormat = AVAudioFormat(
                    commonFormat: AVAudioCommonFormat.pcmFormatInt16,   // short int samples
                    sampleRate: Double(sampleRate),
                    channels:AVAudioChannelCount(2),
                    interleaved: true
                )
                try bus0.setFormat(audioFormat!)
                
                audioUnit.outputProvider = {
                    (actionFlags, timestamp, frameCount, inputBusNumber, inputDataList ) -> AUAudioUnitStatus in
                    self.fillSpeakerBuffer(inputDataList: inputDataList, frameCount: frameCount)
                    return(0)
                }
            }
            
            audioUnit.isOutputEnabled = true
            toneCount = 0
            
            try audioUnit.allocateRenderResources()  //  v2 AudioUnitInitialize()
            try audioUnit.startHardware()            //  v2 AudioOutputUnitStart()
            audioUnit_isRunning = true
        } catch /* let error as NSError */ {
            // handleError(error, functionName: "AUAudioUnit failed")
            // or assert(false)
        }
    }
    
    func stop() {
        if (audioUnit_isRunning) {
            audioUnit.stopHardware()
            audioUnit_isRunning = false
        }
    }
    
    //MARK: Helpers
    private func setAndActivate_audioSession(){
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(AVAudioSessionCategorySoloAmbient)
            
            var preferredIOBufferDuration = 4.0 * 0.0058    // 5.8 milliseconds = 256 samples
            let hwSRate = audioSession.sampleRate           // get native hardware rate
            if hwSRate == 48000.0 { sampleRate = 48000.0 }  // set session to hardware rate
            if hwSRate == 48000.0 { preferredIOBufferDuration = 4.0 * 0.0053 }
            let desiredSampleRate = sampleRate
            try audioSession.setPreferredSampleRate(desiredSampleRate)
            try audioSession.setPreferredIOBufferDuration(preferredIOBufferDuration)
            
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name.AVAudioSessionInterruption,
                object: nil,
                queue: nil,
                using: myAudioSessionInterruptionHandler
            )
            
            try audioSession.setActive(true)
            audioSession_isActive = true
        } catch {
            fatalError("error 85646537")
        }
    }
    
    // process RemoteIO Buffer for output
    private func fillSpeakerBuffer(inputDataList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32){
        
        let inputDataPtr = UnsafeMutableAudioBufferListPointer(inputDataList)
        guard inputDataPtr.count > 0 else {return}
        
        let mBuffers: AudioBuffer = inputDataPtr[0]

        let count = Int(frameCount)
        
        // Speaker Output == play tone at frequency f0
        if (self.v0 > 0) && (self.toneCount > 0){
            var v  = self.v0
            if v > 32767 { v = 32767 }
            
            let sz = Int(mBuffers.mDataByteSize)
            
            var a  = self.phY        // capture from object for use inside block
            let d  = 2.0 * Double.pi * self.f0 / self.sampleRate     // phase delta
            
            let bufferPointer = UnsafeMutableRawPointer(mBuffers.mData)
            if var bptr = bufferPointer {
                for i in 0..<(count) {
                    let u = sin(a)             // create a sinewave
                    a += d ; if (a > 2.0 * Double.pi) { a -= 2.0 * Double.pi }
                    let x = Int16(v * u + 0.5)      // scale & round
                    
                    if (i < (sz / 2)) {
                        bptr.assumingMemoryBound(to: Int16.self).pointee = x
                        bptr += 2   // increment by 2 bytes for next Int16 item
                        bptr.assumingMemoryBound(to: Int16.self).pointee = x
                        bptr += 2   // stereo, so fill both Left & Right channels
                    }
                }
            }
            
            self.phY = a                   // save sinewave phase
            self.toneCount -= Int32(frameCount)   // decrement time remaining
        } else {
            memset(mBuffers.mData, 0, Int(mBuffers.mDataByteSize))  // silence
        }
    }
    
    private func myAudioSessionInterruptionHandler( notification: Notification ) -> Void {
        guard  let interuptionType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] else { return }
        let interuptionValue = AVAudioSessionInterruptionType(rawValue: (interuptionType as AnyObject).uintValue)
        guard interuptionValue == AVAudioSessionInterruptionType.began else { return }
        
        if (audioUnit_isRunning) {
            audioUnit.stopHardware()
            audioUnit_isRunning = false
            interrupted = true
        }
    }
}
