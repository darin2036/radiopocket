import Foundation

// Stock Winamp.q1 numeric curves, with the stock neutral byte mapped to 0 dB.
// Source and processing differences are documented in README.
extension EQPreset {
    static let classic: [EQPreset] = [
        EQPreset(name: "Classical", preamp: 0, bands: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -4.875, -4.875, -4.875, -6.375]),
        EQPreset(name: "Club", preamp: 0, bands: [0.0, 0.0, 1.875, 3.375, 3.375, 3.375, 1.875, 0.0, 0.0, 0.0]),
        EQPreset(name: "Dance", preamp: 0, bands: [5.625, 4.125, 1.125, -0.375, -0.375, -4.125, -4.875, -4.875, -0.375, -0.375]),
        EQPreset(name: "Flat", preamp: 0, bands: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
        EQPreset(name: "Laptop speakers/headphones", preamp: 0, bands: [2.625, 6.375, 3.0, -2.625, -1.875, 0.75, 2.625, 5.625, 7.5, 8.625]),
        EQPreset(name: "Large hall", preamp: 0, bands: [6.0, 6.0, 3.375, 3.375, 0.0, -3.375, -3.375, -3.375, 0.0, 0.0]),
        EQPreset(name: "Party", preamp: 0, bands: [4.125, 4.125, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 4.125, 4.125]),
        EQPreset(name: "Pop", preamp: 0, bands: [-1.5, 2.625, 4.125, 4.5, 3.0, -1.125, -1.875, -1.875, -1.5, -1.5]),
        EQPreset(name: "Reggae", preamp: 0, bands: [0.0, 0.0, -0.75, -4.125, 0.0, 3.75, 3.75, 0.0, 0.0, 0.0]),
        EQPreset(name: "Rock", preamp: 0, bands: [4.5, 2.625, -3.75, -5.25, -2.625, 2.25, 5.25, 6.375, 6.375, 6.375]),
        EQPreset(name: "Soft", preamp: 0, bands: [2.625, 0.75, -1.125, -1.875, -1.125, 2.25, 4.875, 5.625, 6.375, 7.125]),
        EQPreset(name: "Ska", preamp: 0, bands: [-1.875, -3.375, -3.0, -0.75, 2.25, 3.375, 5.25, 5.625, 6.375, 5.625]),
        EQPreset(name: "Full Bass", preamp: 0, bands: [5.625, 5.625, 5.625, 3.375, 0.75, -3.0, -5.625, -6.75, -7.125, -7.125]),
        EQPreset(name: "Soft Rock", preamp: 0, bands: [2.25, 2.25, 1.125, -0.75, -3.0, -3.75, -2.625, -0.75, 1.5, 5.25]),
        EQPreset(name: "Full Treble", preamp: 0, bands: [-6.375, -6.375, -6.375, -3.0, 1.5, 6.375, 9.375, 9.375, 9.375, 10.125]),
        EQPreset(name: "Full Bass & Treble", preamp: 0, bands: [4.125, 3.375, 0.0, -4.875, -3.375, 0.75, 4.875, 6.375, 7.125, 7.125]),
        EQPreset(name: "Live", preamp: 0, bands: [-3.375, 0.0, 2.25, 3.0, 3.375, 3.375, 2.25, 1.5, 1.5, 1.125]),
        EQPreset(name: "Techno", preamp: 0, bands: [4.5, 3.375, 0.0, -3.75, -3.375, 0.0, 4.5, 5.625, 5.625, 5.25]),
    ]
}
