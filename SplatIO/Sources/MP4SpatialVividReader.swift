import Foundation

/// Parses ISOBMFF boxes to extract a Spatial Vivid GLB payload embedded in an MP4.
/// Layout: ftyp(glti brand) → moov/trak (ordinary video/audio) → meta{hdlr=gltf, iloc, iinf, idat}.
struct MP4SpatialVividDemuxer {
    let data: Data

    enum DemuxError: Error {
        case notSpatialVividMP4
        case missingMetaBox
        case missingBoxes
        case glbExtractionFailed
    }

    struct ItemLocation {
        var itemID: UInt16
        var extentOffset: UInt64
        var extentLength: UInt64
    }

    /// Returns the embedded GLB payload.
    func extractGLB() throws -> Data {
        let boxes = try parseBoxes(data, 0, UInt64(data.count))
        guard let ftyp = boxes.first(where: { $0.type == b("ftyp") }),
              ftypPayload(ftyp).contains(b("glti")) else {
            throw DemuxError.notSpatialVividMP4
        }
        guard let meta = boxes.first(where: { $0.type == b("meta") }) else {
            throw DemuxError.missingMetaBox
        }
        // meta is a fullbox: 4 bytes of version/flags before children
        let children = try parseBoxes(data, UInt64(meta.payloadStart + 4), UInt64(meta.payloadStart + meta.payloadSize))

        guard let hdlr = children.first(where: { $0.type == b("hdlr") }),
              payloadBytes(hdlr).dropFirst(8).prefix(4).elementsEqual(b("gltf")),
              let iloc = children.first(where: { $0.type == b("iloc") }),
              let idat = children.first(where: { $0.type == b("idat") }) else {
            throw DemuxError.missingBoxes
        }

        let locations = try parseILoc(Data(payloadBytes(iloc)))
        guard let loc = locations.first else { throw DemuxError.glbExtractionFailed }

        // iloc offsets are relative to the idat payload
        let idatData = payloadBytes(idat)
        let start = Int(loc.extentOffset)
        let end = start + Int(loc.extentLength)
        guard start >= 0, end <= idatData.count else { throw DemuxError.glbExtractionFailed }
        return Data(idatData[start..<end])
    }

    // MARK: - Box parsing

    struct Box {
        var type: [UInt8]
        var payloadStart: Int    // first payload byte
        var payloadSize: Int
    }

    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func payloadBytes(_ box: Box) -> [UInt8] {
        guard box.payloadStart + box.payloadSize <= data.count else { return [] }
        return Array(data.subdata(in: box.payloadStart..<box.payloadStart+box.payloadSize))
    }

    private func ftypPayload(_ box: Box) -> [UInt8] {
        // ftyp: major_brand(4) + minor_version(4) + compatible_brands...
        payloadBytes(box)
    }

    private func parseBoxes(_ data: Data, _ start: UInt64, _ end: UInt64) throws -> [Box] {
        var boxes: [Box] = []
        var offset = start
        while offset + 8 <= end {
            let size32 = UInt64(readUInt32BE(data, Int(offset)))
            let type = Array(data.subdata(in: Int(offset)+4..<Int(offset)+8))
            var size = size32
            var payloadStart = offset + 8
            if size32 == 1 {
                guard offset + 16 <= end else { break }
                size = readUInt64BE(data, Int(offset)+8)
                payloadStart = offset + 16
            } else if size32 == 0 {
                size = end - offset
            }
            // A box must be at least its own header (8 bytes) and fit in the range.
            guard size >= payloadStart - offset, offset + size <= end, size >= 8 else { break }
            let payloadSize = Int(size) - Int(payloadStart - offset)
            if payloadSize > 0 {
                boxes.append(Box(type: type, payloadStart: Int(payloadStart), payloadSize: payloadSize))
            }
            // Always advance — boxes with empty payloads (free) are skipped, not fatal.
            offset += size
        }
        return boxes
    }

    // MARK: - iloc parsing (version 0/1)

    private func parseILoc(_ payload: Data) throws -> [ItemLocation] {
        guard payload.count >= 10 else { return [] }
        let version = payload[0]
        var pos = 4 // skip version/flags
        let sizes = payload[pos]
        let offsetSize = Int(sizes >> 4)
        let lengthSize = Int(sizes & 0xf)
        let baseOffsetSize = Int(payload[pos+1] >> 4)
        let indexSize = (version == 2) ? Int(payload[pos+2] >> 4) : 0
        pos += (version == 2) ? 4 : 2
        guard payload.count >= pos + 2 else { return [] }
        let itemCount = Int(readUInt16BE(payload, pos))
        pos += 2

        var locations: [ItemLocation] = []
        for _ in 0..<itemCount {
            guard payload.count >= pos + 2 else { break }
            let itemID = readUInt16BE(payload, pos)
            pos += 2
            if version == 1 || version == 2 { pos += 2 } // reserved+construction
            pos += 2 // data reference index
            var baseOffset: UInt64 = 0
            for _ in 0..<baseOffsetSize {
                baseOffset = (baseOffset << 8) | UInt64(payload[pos]); pos += 1
            }
            guard payload.count >= pos + 2 else { break }
            let extentCount = Int(readUInt16BE(payload, pos))
            pos += 2
            for _ in 0..<extentCount {
                if indexSize > 0 { pos += indexSize }
                var extentOffset: UInt64 = 0
                for _ in 0..<offsetSize {
                    extentOffset = (extentOffset << 8) | UInt64(payload[pos]); pos += 1
                }
                var extentLength: UInt64 = 0
                for _ in 0..<lengthSize {
                    extentLength = (extentLength << 8) | UInt64(payload[pos]); pos += 1
                }
                locations.append(ItemLocation(itemID: itemID,
                                              extentOffset: baseOffset + extentOffset,
                                              extentLength: extentLength))
            }
        }
        return locations
    }

    private func readUInt16BE(_ d: Data, _ pos: Int) -> UInt16 {
        UInt16(d[pos]) << 8 | UInt16(d[pos+1])
    }
    private func readUInt32BE(_ d: Data, _ pos: Int) -> UInt32 {
        UInt32(d[pos]) << 24 | UInt32(d[pos+1]) << 16 | UInt32(d[pos+2]) << 8 | UInt32(d[pos+3])
    }
    private func readUInt64BE(_ d: Data, _ pos: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(d[pos+i]) }
        return v
    }
}
