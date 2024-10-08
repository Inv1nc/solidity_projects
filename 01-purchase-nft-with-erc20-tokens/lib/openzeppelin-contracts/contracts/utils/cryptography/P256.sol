// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "../math/Math.sol";
import {Errors} from "../Errors.sol";

/**
 * @dev Implementation of secp256r1 verification and recovery functions.
 *
 * The secp256r1 curve (also known as P256) is a NIST standard curve with wide support in modern devices
 * and cryptographic standards. Some notable examples include Apple's Secure Enclave and Android's Keystore
 * as well as authentication protocols like FIDO2.
 *
 * Based on the original https://github.com/itsobvioustech/aa-passkeys-wallet/blob/main/src/Secp256r1.sol[implementation of itsobvioustech].
 * Heavily inspired in https://github.com/maxrobot/elliptic-solidity/blob/master/contracts/Secp256r1.sol[maxrobot] and
 * https://github.com/tdrerup/elliptic-curve-solidity/blob/master/contracts/curves/EllipticCurve.sol[tdrerup] implementations.
 */
library P256 {
    struct JPoint {
        uint256 x;
        uint256 y;
        uint256 z;
    }

    /// @dev Generator (x component)
    uint256 internal constant GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
    /// @dev Generator (y component)
    uint256 internal constant GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;
    /// @dev P (size of the field)
    uint256 internal constant P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF;
    /// @dev N (order of G)
    uint256 internal constant N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    /// @dev A parameter of the weierstrass equation
    uint256 internal constant A = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC;
    /// @dev B parameter of the weierstrass equation
    uint256 internal constant B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B;

    /// @dev (P + 1) / 4. Useful to compute sqrt
    uint256 private constant P1DIV4 = 0x3fffffffc0000000400000000000000000000000400000000000000000000000;

    /// @dev N/2 for excluding higher order `s` values
    uint256 private constant HALF_N = 0x7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8;

    /**
     * @dev Verifies a secp256r1 signature using the RIP-7212 precompile and falls back to the Solidity implementation
     * if the precompile is not available. This version should work on all chains, but requires the deployment of more
     * bytecode.
     *
     * @param h - hashed message
     * @param r - signature half R
     * @param s - signature half S
     * @param qx - public key coordinate X
     * @param qy - public key coordinate Y
     *
     * IMPORTANT: This function disallows signatures where the `s` value is above `N/2` to prevent malleability.
     * To flip the `s` value, compute `s = N - s`.
     */
    function verify(bytes32 h, bytes32 r, bytes32 s, bytes32 qx, bytes32 qy) internal view returns (bool) {
        (bool valid, bool supported) = _tryVerifyNative(h, r, s, qx, qy);
        return supported ? valid : verifySolidity(h, r, s, qx, qy);
    }

    /**
     * @dev Same as {verify}, but it will revert if the required precompile is not available.
     *
     * Make sure any logic (code or precompile) deployed at that address is the expected one,
     * otherwise the returned value may be misinterpreted as a positive boolean.
     */
    function verifyNative(bytes32 h, bytes32 r, bytes32 s, bytes32 qx, bytes32 qy) internal view returns (bool) {
        (bool valid, bool supported) = _tryVerifyNative(h, r, s, qx, qy);
        if (supported) {
            return valid;
        } else {
            revert Errors.MissingPrecompile(address(0x100));
        }
    }

    /**
     * @dev Same as {verify}, but it will return false if the required precompile is not available.
     */
    function _tryVerifyNative(
        bytes32 h,
        bytes32 r,
        bytes32 s,
        bytes32 qx,
        bytes32 qy
    ) private view returns (bool valid, bool supported) {
        if (!_isProperSignature(r, s) || !isValidPublicKey(qx, qy)) {
            return (false, true); // signature is invalid, and its not because the precompile is missing
        }

        (bool success, bytes memory returndata) = address(0x100).staticcall(abi.encode(h, r, s, qx, qy));
        return (success && returndata.length == 0x20) ? (abi.decode(returndata, (bool)), true) : (false, false);
    }

    /**
     * @dev Same as {verify}, but only the Solidity implementation is used.
     */
    function verifySolidity(bytes32 h, bytes32 r, bytes32 s, bytes32 qx, bytes32 qy) internal view returns (bool) {
        if (!_isProperSignature(r, s) || !isValidPublicKey(qx, qy)) {
            return false;
        }

        JPoint[16] memory points = _preComputeJacobianPoints(uint256(qx), uint256(qy));
        uint256 w = Math.invModPrime(uint256(s), N);
        uint256 u1 = mulmod(uint256(h), w, N);
        uint256 u2 = mulmod(uint256(r), w, N);
        (uint256 x, ) = _jMultShamir(points, u1, u2);
        return ((x % N) == uint256(r));
    }

    /**
     * @dev Public key recovery
     *
     * @param h - hashed message
     * @param v - signature recovery param
     * @param r - signature half R
     * @param s - signature half S
     *
     * IMPORTANT: This function disallows signatures where the `s` value is above `N/2` to prevent malleability.
     * To flip the `s` value, compute `s = N - s` and `v = 1 - v` if (`v = 0 | 1`).
     */
    function recovery(bytes32 h, uint8 v, bytes32 r, bytes32 s) internal view returns (bytes32, bytes32) {
        if (!_isProperSignature(r, s) || v > 1) {
            return (0, 0);
        }

        uint256 rx = uint256(r);
        uint256 ry2 = addmod(mulmod(addmod(mulmod(rx, rx, P), A, P), rx, P), B, P); // weierstrass equation y² = x³ + a.x + b
        uint256 ry = Math.modExp(ry2, P1DIV4, P); // This formula for sqrt work because P ≡ 3 (mod 4)
        if (mulmod(ry, ry, P) != ry2) return (0, 0); // Sanity check
        if (ry % 2 != v % 2) ry = P - ry;

        JPoint[16] memory points = _preComputeJacobianPoints(rx, ry);
        uint256 w = Math.invModPrime(uint256(r), N);
        uint256 u1 = mulmod(N - (uint256(h) % N), w, N);
        uint256 u2 = mulmod(uint256(s), w, N);
        (uint256 x, uint256 y) = _jMultShamir(points, u1, u2);
        return (bytes32(x), bytes32(y));
    }

    /**
     * @dev Checks if (x, y) are valid coordinates of a point on the curve.
     * In particular this function checks that x <= P and y <= P.
     */
    function isValidPublicKey(bytes32 x, bytes32 y) internal pure returns (bool result) {
        assembly ("memory-safe") {
            let lhs := mulmod(y, y, P) // y^2
            let rhs := addmod(mulmod(addmod(mulmod(x, x, P), A, P), x, P), B, P) // ((x^2 + a) * x) + b = x^3 + ax + b
            result := and(and(lt(x, P), lt(y, P)), eq(lhs, rhs)) // Should conform with the Weierstrass equation
        }
    }

    /**
     * @dev Checks if (r, s) is a proper signature.
     * In particular, this checks that `s` is in the "lower-range", making the signature non-malleable.
     */
    function _isProperSignature(bytes32 r, bytes32 s) private pure returns (bool) {
        return uint256(r) > 0 && uint256(r) < N && uint256(s) > 0 && uint256(s) <= HALF_N;
    }

    /**
     * @dev Reduce from jacobian to affine coordinates
     * @param jx - jacobian coordinate x
     * @param jy - jacobian coordinate y
     * @param jz - jacobian coordinate z
     * @return ax - affine coordinate x
     * @return ay - affine coordinate y
     */
    function _affineFromJacobian(uint256 jx, uint256 jy, uint256 jz) private view returns (uint256 ax, uint256 ay) {
        if (jz == 0) return (0, 0);
        uint256 zinv = Math.invModPrime(jz, P);
        uint256 zzinv = mulmod(zinv, zinv, P);
        uint256 zzzinv = mulmod(zzinv, zinv, P);
        ax = mulmod(jx, zzinv, P);
        ay = mulmod(jy, zzzinv, P);
    }

    /**
     * @dev Point addition on the jacobian coordinates
     * Reference: https://www.hyperelliptic.org/EFD/g1p/auto-shortw-jacobian.html#addition-add-1998-cmo-2
     */
    function _jAdd(
        JPoint memory p1,
        uint256 x2,
        uint256 y2,
        uint256 z2
    ) private pure returns (uint256 rx, uint256 ry, uint256 rz) {
        assembly ("memory-safe") {
            let z1 := mload(add(p1, 0x40))
            let s1 := mulmod(mload(add(p1, 0x20)), mulmod(mulmod(z2, z2, P), z2, P), P) // s1 = y1*z2³
            let s2 := mulmod(y2, mulmod(mulmod(z1, z1, P), z1, P), P) // s2 = y2*z1³
            let r := addmod(s2, sub(P, s1), P) // r = s2-s1
            let u1 := mulmod(mload(p1), mulmod(z2, z2, P), P) // u1 = x1*z2²
            let u2 := mulmod(x2, mulmod(z1, z1, P), P) // u2 = x2*z1²
            let h := addmod(u2, sub(P, u1), P) // h = u2-u1
            let hh := mulmod(h, h, P) // h²

            // x' = r²-h³-2*u1*h²
            rx := addmod(
                addmod(mulmod(r, r, P), sub(P, mulmod(h, hh, P)), P),
                sub(P, mulmod(2, mulmod(u1, hh, P), P)),
                P
            )
            // y' = r*(u1*h²-x')-s1*h³
            ry := addmod(
                mulmod(r, addmod(mulmod(u1, hh, P), sub(P, rx), P), P),
                sub(P, mulmod(s1, mulmod(h, hh, P), P)),
                P
            )
            // z' = h*z1*z2
            rz := mulmod(h, mulmod(z1, z2, P), P)
        }
    }

    /**
     * @dev Point doubling on the jacobian coordinates
     * Reference: https://www.hyperelliptic.org/EFD/g1p/auto-shortw-jacobian.html#doubling-dbl-1998-cmo-2
     */
    function _jDouble(uint256 x, uint256 y, uint256 z) private pure returns (uint256 rx, uint256 ry, uint256 rz) {
        assembly ("memory-safe") {
            let yy := mulmod(y, y, P)
            let zz := mulmod(z, z, P)
            let s := mulmod(4, mulmod(x, yy, P), P) // s = 4*x*y²
            let m := addmod(mulmod(3, mulmod(x, x, P), P), mulmod(A, mulmod(zz, zz, P), P), P) // m = 3*x²+a*z⁴
            let t := addmod(mulmod(m, m, P), sub(P, mulmod(2, s, P)), P) // t = m²-2*s

            // x' = t
            rx := t
            // y' = m*(s-t)-8*y⁴
            ry := addmod(mulmod(m, addmod(s, sub(P, t), P), P), sub(P, mulmod(8, mulmod(yy, yy, P), P)), P)
            // z' = 2*y*z
            rz := mulmod(2, mulmod(y, z, P), P)
        }
    }

    /**
     * @dev Compute P·u1 + Q·u2 using the precomputed points for P and Q (see {_preComputeJacobianPoints}).
     *
     * Uses Strauss Shamir trick for EC multiplication
     * https://stackoverflow.com/questions/50993471/ec-scalar-multiplication-with-strauss-shamir-method
     * we optimise on this a bit to do with 2 bits at a time rather than a single bit
     * the individual points for a single pass are precomputed
     * overall this reduces the number of additions while keeping the same number of doublings
     */
    function _jMultShamir(JPoint[16] memory points, uint256 u1, uint256 u2) private view returns (uint256, uint256) {
        uint256 x = 0;
        uint256 y = 0;
        uint256 z = 0;
        unchecked {
            for (uint256 i = 0; i < 128; ++i) {
                if (z > 0) {
                    (x, y, z) = _jDouble(x, y, z);
                    (x, y, z) = _jDouble(x, y, z);
                }
                // Read 2 bits of u1, and 2 bits of u2. Combining the two give a lookup index in the table.
                uint256 pos = ((u1 >> 252) & 0xc) | ((u2 >> 254) & 0x3);
                if (pos > 0) {
                    if (z == 0) {
                        (x, y, z) = (points[pos].x, points[pos].y, points[pos].z);
                    } else {
                        (x, y, z) = _jAdd(points[pos], x, y, z);
                    }
                }
                u1 <<= 2;
                u2 <<= 2;
            }
        }
        return _affineFromJacobian(x, y, z);
    }

    /**
     * @dev Precompute a matrice of useful jacobian points associated with a given P. This can be seen as a 4x4 matrix
     * that contains combination of P and G (generator) up to 3 times each. See the table below:
     *
     * ┌────┬─────────────────────┐
     * │  i │  0    1     2     3 │
     * ├────┼─────────────────────┤
     * │  0 │  0    p    2p    3p │
     * │  4 │  g  g+p  g+2p  g+3p │
     * │  8 │ 2g 2g+p 2g+2p 2g+3p │
     * │ 12 │ 3g 3g+p 3g+2p 3g+3p │
     * └────┴─────────────────────┘
     */
    function _preComputeJacobianPoints(uint256 px, uint256 py) private pure returns (JPoint[16] memory points) {
        points[0x00] = JPoint(0, 0, 0); // 0,0
        points[0x01] = JPoint(px, py, 1); // 1,0 (p)
        points[0x04] = JPoint(GX, GY, 1); // 0,1 (g)
        points[0x02] = _jDoublePoint(points[0x01]); // 2,0 (2p)
        points[0x08] = _jDoublePoint(points[0x04]); // 0,2 (2g)
        points[0x03] = _jAddPoint(points[0x01], points[0x02]); // 3,0 (3p)
        points[0x05] = _jAddPoint(points[0x01], points[0x04]); // 1,1 (p+g)
        points[0x06] = _jAddPoint(points[0x02], points[0x04]); // 2,1 (2p+g)
        points[0x07] = _jAddPoint(points[0x03], points[0x04]); // 3,1 (3p+g)
        points[0x09] = _jAddPoint(points[0x01], points[0x08]); // 1,2 (p+2g)
        points[0x0a] = _jAddPoint(points[0x02], points[0x08]); // 2,2 (2p+2g)
        points[0x0b] = _jAddPoint(points[0x03], points[0x08]); // 3,2 (3p+2g)
        points[0x0c] = _jAddPoint(points[0x04], points[0x08]); // 0,3 (g+2g)
        points[0x0d] = _jAddPoint(points[0x01], points[0x0c]); // 1,3 (p+3g)
        points[0x0e] = _jAddPoint(points[0x02], points[0x0c]); // 2,3 (2p+3g)
        points[0x0f] = _jAddPoint(points[0x03], points[0x0C]); // 3,3 (3p+3g)
    }

    function _jAddPoint(JPoint memory p1, JPoint memory p2) private pure returns (JPoint memory) {
        (uint256 x, uint256 y, uint256 z) = _jAdd(p1, p2.x, p2.y, p2.z);
        return JPoint(x, y, z);
    }

    function _jDoublePoint(JPoint memory p) private pure returns (JPoint memory) {
        (uint256 x, uint256 y, uint256 z) = _jDouble(p.x, p.y, p.z);
        return JPoint(x, y, z);
    }
}
