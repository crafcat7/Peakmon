//
//  CardWidth.swift
//  Peakmon
//
//  Fixed Popover width roles. Primary metrics pair as half-width
//  cards; Battery and Processes use compact full-width rows. Keeping
//  this as an explicit value makes `DashboardLayout` easy to test
//  without exposing width as a user preference.
//

enum CardWidth: Equatable {
    /// Card spans the full popover row. Required for cards whose
    /// content does not compress well — sparklines that need wide
    /// horizontal range, multi-stat headers, etc.
    case full

    /// Card occupies half a popover row. Two adjacent half cards in
    /// the user's visible order render side-by-side in an `HStack`.
    /// A trailing un-paired half is promoted to a full-width row.
    case half

    /// Product layout. The dashboard ships with a paired-row layout:
    /// CPU/Memory, GPU/Power, Disk/Network occupy three half-width
    /// rows; Battery and Processes take compact full-width rows.
    static func defaultValue(for slot: CardTintSlot) -> CardWidth {
        switch slot {
        case .battery, .processes: .full
        case .cpu, .memory, .disk, .network, .gpu, .power: .half
        }
    }
}
