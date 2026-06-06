//
//  PeakmonCollectors.swift
//  PeakmonCollectors
//
//  Concrete metric collectors. Split into three buckets:
//    • Public/  — collectors using only public Apple APIs
//    • Private/ — collectors using private/undocumented APIs (Sensors/GPU/Fan)
//    • Helper/  — collectors that talk to the privileged helper over XPC
//
//  v0.1 will introduce CPUCollector / MemoryCollector / BatteryCollector
//  under Public/.
//
