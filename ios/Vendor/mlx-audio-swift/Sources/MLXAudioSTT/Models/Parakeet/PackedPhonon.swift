import Foundation
import MLX
import MLXNN

/// Exact execution of one Phonon five-value matrix using two native MLX 2-bit
/// affine QMMs. The inherited zero-sized `weight` is never used; it merely
/// satisfies the upstream `Linear` storage contract after the dense module is
/// replaced. No full dense matrix is retained in the final module tree.
final class PackedFiveValueLinear: Linear {
    @ParameterInfo(key: "base_q") var baseQ: MLXArray
    @ParameterInfo(key: "residual_q") var residualQ: MLXArray
    @ParameterInfo(key: "row_lo") var rowLo: MLXArray
    @ParameterInfo(key: "row_delta") var rowDelta: MLXArray
    let inputFeatures: Int
    let outputFeatures: Int

    init(baseQ: MLXArray, residualQ: MLXArray, rowLo: MLXArray, rowDelta: MLXArray, inputFeatures: Int, outputFeatures: Int, bias: MLXArray?) {
        precondition(inputFeatures % 128 == 0 && inputFeatures % 16 == 0)
        precondition(baseQ.shape == [outputFeatures, inputFeatures / 16])
        precondition(residualQ.shape == [outputFeatures, inputFeatures / 16])
        precondition(rowLo.shape == [outputFeatures] && rowDelta.shape == [outputFeatures])
        self._baseQ = ParameterInfo(wrappedValue: baseQ, key: "base_q")
        self._residualQ = ParameterInfo(wrappedValue: residualQ, key: "residual_q")
        self._rowLo = ParameterInfo(wrappedValue: rowLo, key: "row_lo")
        self._rowDelta = ParameterInfo(wrappedValue: rowDelta, key: "row_delta")
        self.inputFeatures = inputFeatures
        self.outputFeatures = outputFeatures
        super.init(weight: MLXArray.zeros([0, 0]), bias: bias)
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        precondition(x.shape.last == inputFeatures, "packed Phonon input width mismatch")
        let groups = inputFeatures / 128
        let lo = rowLo.asType(.float32).reshaped([outputFeatures, 1])
        let delta = rowDelta.asType(.float32).reshaped([outputFeatures, 1])
        let baseScales = contiguous(broadcast(lo, to: [outputFeatures, groups]))
        let residualScales = contiguous(broadcast(delta, to: [outputFeatures, groups]))
        let baseBiases = contiguous(-baseScales)
        let residualBiases = contiguous(-residualScales)
        let x32 = x.asType(.float32)
        var y = quantizedMM(x32, baseQ, scales: baseScales, biases: baseBiases,
                            transpose: true, groupSize: 128, bits: 2, mode: .affine)
        y = y + quantizedMM(x32, residualQ, scales: residualScales, biases: residualBiases,
                            transpose: true, groupSize: 128, bits: 2, mode: .affine)
        if let bias { y = y + bias.asType(.float32) }
        return y.asType(x.dtype)
    }
}

final class PackedFiveValueConv1d: Conv1d {
    @ParameterInfo(key: "base_q") var baseQ: MLXArray
    @ParameterInfo(key: "residual_q") var residualQ: MLXArray
    @ParameterInfo(key: "row_lo") var rowLo: MLXArray
    @ParameterInfo(key: "row_delta") var rowDelta: MLXArray
    @ParameterInfo(key: "bias") var trainedBias: MLXArray?
    let inputFeatures: Int
    let outputFeatures: Int

    init(baseQ: MLXArray, residualQ: MLXArray, rowLo: MLXArray, rowDelta: MLXArray, inputFeatures: Int, outputFeatures: Int, bias: MLXArray?) {
        precondition(inputFeatures % 128 == 0 && inputFeatures % 16 == 0)
        self._baseQ = ParameterInfo(wrappedValue: baseQ, key: "base_q")
        self._residualQ = ParameterInfo(wrappedValue: residualQ, key: "residual_q")
        self._rowLo = ParameterInfo(wrappedValue: rowLo, key: "row_lo")
        self._rowDelta = ParameterInfo(wrappedValue: rowDelta, key: "row_delta")
        self._trainedBias = ParameterInfo(wrappedValue: bias, key: "bias")
        self.inputFeatures = inputFeatures
        self.outputFeatures = outputFeatures
        super.init(inputChannels: 1, outputChannels: 1, kernelSize: 1, bias: false)
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        precondition(x.shape.last == inputFeatures, "packed Phonon Conv1d input width mismatch")
        let groups = inputFeatures / 128
        let baseScales = contiguous(broadcast(rowLo.asType(.float32).reshaped([outputFeatures, 1]), to: [outputFeatures, groups]))
        let residualScales = contiguous(broadcast(rowDelta.asType(.float32).reshaped([outputFeatures, 1]), to: [outputFeatures, groups]))
        let baseBiases = contiguous(-baseScales)
        let residualBiases = contiguous(-residualScales)
        let x32 = x.asType(.float32)
        var y = quantizedMM(x32, baseQ, scales: baseScales, biases: baseBiases, transpose: true, groupSize: 128, bits: 2, mode: .affine)
        y = y + quantizedMM(x32, residualQ, scales: residualScales, biases: residualBiases, transpose: true, groupSize: 128, bits: 2, mode: .affine)
        if let trainedBias { y = y + trainedBias.asType(.float32) }
        return y.asType(x.dtype)
    }
}

private func packedStem(_ key: String) -> String? {
    key.hasSuffix(".base_q") ? String(key.dropLast(".base_q".count)) : nil
}

private func replacementModule(stem: String, module: PackedFiveValueLinear, conv: PackedFiveValueConv1d?) throws -> Module {
    let parts = stem.split(separator: ".").map(String.init)
    guard parts.count >= 5, parts[0] == "encoder", parts[1] == "layers", Int(parts[2]) != nil else {
        throw NSError(domain: "KlangschriftPacked", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid packed module path \(stem)"])
    }
    switch Array(parts.dropFirst(3)) {
    case ["feed_forward1", "linear1"], ["feed_forward1", "linear2"], ["feed_forward2", "linear1"], ["feed_forward2", "linear2"]:
        return module
    case ["conv", "pointwise_conv1"]:
        guard let conv else { throw NSError(domain: "KlangschriftPacked", code: 7) }
        return conv
    case ["conv", "pointwise_conv2"]:
        guard let conv else { throw NSError(domain: "KlangschriftPacked", code: 7) }
        return conv
    case ["self_attn", "linear_q"], ["self_attn", "linear_k"], ["self_attn", "linear_v"], ["self_attn", "linear_out"], ["self_attn", "linear_pos"]:
        return module
    default: throw NSError(domain: "KlangschriftPacked", code: 2, userInfo: [NSLocalizedDescriptionKey: "unsupported packed module \(stem)"])
    }
}

/// Replaces all 264 five-value encoder modules and strictly verifies the
/// remaining dense parameter key set before loading it.
func loadPackedPhonon(model: ParakeetModel, weights: [String: MLXArray]) throws {
    let stems = Set(weights.keys.compactMap(packedStem))
    guard stems.count == 264 else { throw NSError(domain: "KlangschriftPacked", code: 3, userInfo: [NSLocalizedDescriptionKey: "expected 264 packed modules, found \(stems.count)"]) }
    let flattened = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
    let expected = Set(flattened.keys)
    var packedOriginal = Set<String>()
    var replacements: [String: Module] = [:]
    for stem in stems {
        guard let base = weights[stem + ".base_q"], let residual = weights[stem + ".residual_q"], let lo = weights[stem + ".row_lo"], let delta = weights[stem + ".row_delta"] else {
            throw NSError(domain: "KlangschriftPacked", code: 4, userInfo: [NSLocalizedDescriptionKey: "incomplete planes for \(stem)"])
        }
        let shape = flattened[stem + ".weight"]?.shape
        guard let shape, shape.count == 2 || shape.count == 3 else { throw NSError(domain: "KlangschriftPacked", code: 5, userInfo: [NSLocalizedDescriptionKey: "missing dense shape for \(stem)"]) }
        packedOriginal.insert(stem + ".weight")
        if expected.contains(stem + ".bias") { packedOriginal.insert(stem + ".bias") }
        let inputFeatures = shape.count == 2 ? shape[1] : shape[2]
        let packed = PackedFiveValueLinear(baseQ: base, residualQ: residual, rowLo: lo, rowDelta: delta,
                                            inputFeatures: inputFeatures, outputFeatures: shape[0], bias: weights[stem + ".bias"])
        let conv = stem.contains(".conv.pointwise_") ? PackedFiveValueConv1d(baseQ: base, residualQ: residual, rowLo: lo, rowDelta: delta,
                                                                                inputFeatures: inputFeatures, outputFeatures: shape[0], bias: weights[stem + ".bias"]) : nil
        replacements[stem] = try replacementModule(stem: stem, module: packed, conv: conv)
    }
    try model.update(modules: ModuleChildren.unflattened(replacements), verify: .noUnusedKeys)
    let planeKeys = Set(stems.flatMap { ["\($0).base_q", "\($0).residual_q", "\($0).row_lo", "\($0).row_delta"] })
    let dense = weights.filter { !planeKeys.contains($0.key) && !packedOriginal.contains($0.key) }
    let unexpected = Set(dense.keys).subtracting(expected.subtracting(packedOriginal))
    let missing = expected.subtracting(packedOriginal).subtracting(dense.keys)
    guard unexpected.isEmpty && missing.isEmpty else {
        throw NSError(domain: "KlangschriftPacked", code: 6, userInfo: [NSLocalizedDescriptionKey: "packed dense key mismatch missing=\(missing.count) unexpected=\(unexpected.count)"])
    }
    try model.update(parameters: ModuleParameters.unflattened(dense), verify: .noUnusedKeys)
}
