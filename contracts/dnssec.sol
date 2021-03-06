pragma solidity ^0.4.17;

import "./owned.sol";
import "./bytesutils.sol";
import "./rrutils.sol";
import "./algorithm.sol";
import "./digest.sol";

/*
 * @dev An oracle contract that verifies and stores DNSSEC-validated DNS records.
 *
 * TODO: Support for NSEC records
 */
contract DNSSEC is Owned {
    using BytesUtils for *;
    using RRUtils for *;

    uint16 constant DNSCLASS_IN = 1;

    uint16 constant DNSTYPE_DS = 43;
    uint16 constant DNSTYPE_RRSIG = 46;
    uint16 constant DNSTYPE_DNSKEY = 48;

    uint constant DS_KEY_TAG = 0;
    uint constant DS_ALGORITHM = 2;
    uint constant DS_DIGEST_TYPE = 3;
    uint constant DS_DIGEST = 4;

    uint constant RRSIG_TYPE = 0;
    uint constant RRSIG_ALGORITHM = 2;
    uint constant RRSIG_LABELS = 3;
    uint constant RRSIG_TTL = 4;
    uint constant RRSIG_EXPIRATION = 8;
    uint constant RRSIG_INCEPTION = 12;
    uint constant RRSIG_KEY_TAG = 16;
    uint constant RRSIG_SIGNER_NAME = 18;

    uint constant DNSKEY_FLAGS = 0;
    uint constant DNSKEY_PROTOCOL = 2;
    uint constant DNSKEY_ALGORITHM = 3;
    uint constant DNSKEY_PUBKEY = 4;

    uint constant DNSKEY_FLAG_ZONEKEY = 0x100;

    uint8 constant ALGORITHM_RSASHA256 = 8;

    uint8 constant DIGEST_ALGORITHM_SHA256 = 2;

    struct RRSet {
        uint32 inception;
        uint32 expiration;
        uint64 inserted;
        bytes rrs;
    }

    // (name, type, class) => RRSet
    mapping(bytes32=>mapping(uint16=>mapping(uint16=>RRSet))) rrsets;

    mapping(uint8=>Algorithm) public algorithms;
    mapping(uint8=>Digest) public digests;

    event AlgorithmUpdated(uint8 id, address addr);
    event DigestUpdated(uint8 id, address addr);
    event RRSetUpdated(bytes name);

    /**
     * @dev Constructor.
     * @param anchors The binary format RR entries for the root DS records.
     */
    function DNSSEC(bytes anchors) public {
        // Insert the 'trust anchors' - the key hashes that start the chain
        // of trust for all other records.
        rrsets[keccak256(hex"00")][DNSTYPE_DS][DNSCLASS_IN] = RRSet(
            // Inception
            0,
            // Expiration
            0xFFFFFFFF,
            // Inserted
            uint64(now),
            // RRs
            anchors
        );
    }

    /**
     * @dev Sets the contract address for a signature verification algorithm.
     *      Callable only by the owner.
     * @param id The algorithm ID
     * @param algo The address of the algorithm contract.
     */
    function setAlgorithm(uint8 id, Algorithm algo) public owner_only {
        algorithms[id] = algo;
        AlgorithmUpdated(id, algo);
    }

    /**
     * @dev Sets the contract address for a digest verification algorithm.
     *      Callable only by the owner.
     * @param id The digest ID
     * @param digest The address of the digest contract.
     */
    function setDigest(uint8 id, Digest digest) public owner_only {
        digests[id] = digest;
        DigestUpdated(id, digest);
    }

    /**
     * @dev Returns the RRs (if any) associated with the provided class, type, and name.
     * @param class The DNS class (1 = CLASS_INET) to query.
     * @param dnstype The DNS record type to query.
     * @param name The name to query, in DNS label-sequence format.
     * @return inception The unix timestamp at which the signature for this RRSET was created.
     * @return expiration The unix timestamp at which the signature for this RRSET expires.
     * @return inserted The unix timestamp at which this RRSET was inserted into the oracle.
     * @return rrs The wire-format RR records.
     */
    function rrset(uint16 class, uint16 dnstype, bytes name) public constant returns(uint32 inception, uint32 expiration, uint64 inserted, bytes rrs) {
        var result = rrsets[keccak256(name)][dnstype][class];
        if(result.expiration < now) {
          return (0, 0, 0, "");
        }
        return (result.inception, result.expiration, result.inserted, result.rrs);
    }

    /**
     * @dev Submits a signed set of RRs to the oracle.
     *
     * RRSETs are only accepted if they are signed with a key that is already
     * trusted, or if they are self-signed, and the signing key is identified by
     * a DS record that is already trusted.
     *
     * @param class The DNS class (1 = CLASS_INET) of the records being inserted.
     * @param name The name of the RRSET, in DNS label-sequence format.
     * @param input The signed RR set. This is in the format described in section
     *        5.3.2 of RFC4035: The RRDATA section from the RRSIG without the signature
     *        data, followed by a series of canonicalised RR records that the signature
     *        applies to.
     * @param sig The signature data from the RRSIG record.
     */
    function submitRRSet(uint16 class, bytes name, bytes input, bytes sig) public {
        BytesUtils.slice memory data;
        data.fromBytes(input);

        var inception = data.uint32At(RRSIG_INCEPTION);
        var expiration = data.uint32At(RRSIG_EXPIRATION);
        var typecovered = data.uint16At(RRSIG_TYPE);
        var labels = data.uint8At(RRSIG_LABELS);

        // Validate the signature
        verifySignature(class, name, data, input, sig);

        var set = rrsets[keccak256(name)][typecovered][class];
        if(set.rrs.length > 0) {
            // To replace an existing rrset, the signature must be newer
            assert(inception > set.inception);
        }

        set.inception = inception;
        set.expiration = expiration;
        set.inserted = uint64(now);

        // o  The validator's notion of the current time MUST be less than or
        //    equal to the time listed in the RRSIG RR's Expiration field.
        assert(expiration > now);

        // o  The validator's notion of the current time MUST be greater than or
        //    equal to the time listed in the RRSIG RR's Inception field.
        assert(inception < now);

        insertRRs(set, data, name, class, typecovered, labels);
        RRSetUpdated(name);
    }

    /**
     * @dev Validates and inserts a set of RRs.
     * @param set The storage location to insert the RRs into.
     * @param data The RR data.
     * @param rrsigname The name assigned to the RRSIG record verifying this RRSET.
     * @param rrsetclass The class value for the RRSIG record.
     * @param typecovered The type covered by the RRSIG record.
     * @param labels The number of labels specified by the RRSIG record.
     */
    function insertRRs(RRSet storage set, BytesUtils.slice memory data, bytes rrsigname, uint16 rrsetclass, uint16 typecovered, uint8 labels) internal {
        // Iterate over all the RRs
        BytesUtils.slice memory name;
        BytesUtils.slice memory rdata;
        for(var (dnstype, class, ttl) = data.nextRR(name, rdata); dnstype != 0; (dnstype, class, ttl) = data.nextRR(name, rdata)) {
            // o  The RRSIG RR and the RRset MUST have the same owner name and the
            //    same class.
            require(class == rrsetclass);
            var nameLabels = name.countLabels(0);
            // o  The number of labels in the RRset owner name MUST be greater than
            //    or equal to the value in the RRSIG RR's Labels field.
            if(nameLabels == labels) {
              require(name.keccak() == keccak256(rrsigname));
            } else if(nameLabels == labels + 1) {
              // It's a wildcard domain; make sure it ends with rrsigname and starts with *.
              require(name.suffixOf(2, rrsigname));
              require(name.uint16At(0) == 0x012A);
            } else {
              // Anything else is invalid
              revert();
            }

            // o  The RRSIG RR's Type Covered field MUST equal the RRset's type.
            require(dnstype == typecovered);
        }

        set.rrs = data.toBytes();
    }

    /**
     * @dev Performs signature verification.
     *
     * Throws or reverts if unable to verify the record.
     *
     * @param class The DNS class for the records.
     * @param name The name of the RRSIG record, in DNS label-sequence format.
     * @param rdata The RDATA section of the RRSIG record.
     * @param data The original data to verify.
     * @param sig The signature data.
     */
    function verifySignature(uint16 class, bytes name, BytesUtils.slice memory rdata, bytes data, bytes sig) internal constant {
        // Extract signer name
        BytesUtils.slice memory signerName;
        rdata.dnsNameAt(RRSIG_SIGNER_NAME, signerName);

        // o  The RRSIG RR's Signer's Name field MUST be the name of the zone
        //    that contains the RRset.
        require(signerName.suffixOf(0, name));

        // Extract algorithm and keytag
        var algorithm = rdata.uint8At(RRSIG_ALGORITHM);
        var keytag = rdata.uint16At(RRSIG_KEY_TAG);

        // Update rdata to point at the first RR
        rdata.s(18 + signerName.len, rdata.len);

        // Look for a matching key and verify the signature with it
        var keys = rrsets[signerName.keccak()][DNSTYPE_DNSKEY][class];
        BytesUtils.slice memory keydata;
        keydata.fromBytes(keys.rrs);

        BytesUtils.slice memory keyname;
        BytesUtils.slice memory keyrdata;
        for(var (dnstype,,) = keydata.nextRR(keyname, keyrdata); dnstype != 0; (dnstype,,) = keydata.nextRR(keyname, keyrdata)) {
            if(verifySignatureWithKey(keyrdata, algorithm, keytag, data, sig)) return;
        }

        // Perhaps it's self-signed and verified by a DS record?
        for((dnstype,,) = rdata.nextRR(keyname, keyrdata); dnstype != 0; (dnstype,,) = rdata.nextRR(keyname, keyrdata)) {
            if(dnstype != DNSTYPE_DNSKEY) break;
            if(verifySignatureWithKey(keyrdata, algorithm, keytag, data, sig)) {
                // It's self-signed - look for a DS record to verify it.
                if(verifyKeyWithDS(class, keyname, keyrdata, keytag, algorithm)) return;
                // If we found a valid signature but no valid DS, no use checking other records too.
                break;
            }
        }

        // No valid keys found
        revert();
    }

    /**
     * @dev Attempts to verify some data using a provided key and a signature.
     * @param keyrdata The RDATA section of the key to use.
     * @param algorithm The algorithm ID of the key and signature.
     * @param keytag The keytag from the signature.
     * @param data The data to verify.
     * @param sig The signature to use.
     * @return True if the key verifies the signature.
     */
    function verifySignatureWithKey(BytesUtils.slice memory keyrdata, uint8 algorithm, uint16 keytag, bytes data, bytes sig) internal view returns(bool) {
        if(algorithms[algorithm] == address(0)) return false;
        // TODO: Check key isn't expired, unless updating key itself

        // o The RRSIG RR's Signer's Name, Algorithm, and Key Tag fields MUST
        //   match the owner name, algorithm, and key tag for some DNSKEY RR in
        //   the zone's apex DNSKEY RRset.
        if(keyrdata.uint8At(DNSKEY_PROTOCOL) != 3) return false;
        if(keyrdata.uint8At(DNSKEY_ALGORITHM) != algorithm) return false;
        var computedkeytag = computeKeytag(keyrdata);
        if(computedkeytag != keytag) return false;

        // o The matching DNSKEY RR MUST be present in the zone's apex DNSKEY
        //   RRset, and MUST have the Zone Flag bit (DNSKEY RDATA Flag bit 7)
        //   set.
        if(keyrdata.uint16At(DNSKEY_FLAGS) & DNSKEY_FLAG_ZONEKEY == 0) return false;

        return algorithms[algorithm].verify(keyrdata.toBytes(), data, sig);
    }

    /**
     * @dev Computes the keytag for a chunk of data.
     * @param data The data to compute a keytag for.
     * @return The computed key tag.
     */
    function computeKeytag(BytesUtils.slice memory data) internal pure returns(uint16) {
        uint ac;
        for(uint i = 0; i < data.len; i += 2) {
            ac += data.uint16At(i);
        }
        ac += (ac >> 16) & 0xFFFF;
        return uint16(ac & 0xFFFF);
    }

    /**
     * @dev Attempts to verify a key using DS records.
     * @param class The DNS class of the key.
     * @param keyname The DNS name of the key, in DNS label-sequence format.
     * @param keyrdata The RDATA section of the key.
     * @param keytag The keytag of the key.
     * @param algorithm The algorithm ID of the key.
     * @return True if a DS record verifies this key.
     */
    function verifyKeyWithDS(uint16 class, BytesUtils.slice memory keyname, BytesUtils.slice memory keyrdata, uint16 keytag, uint8 algorithm) internal constant returns (bool) {
        var dss = rrsets[keyname.keccak()][DNSTYPE_DS][class];

        BytesUtils.slice memory data;
        data.fromBytes(dss.rrs);

        BytesUtils.slice memory dsname;
        BytesUtils.slice memory dsrdata;
        for(var (dnstype,,) = data.nextRR(dsname, dsrdata); dnstype != 0; (dnstype,,) = data.nextRR(dsname, dsrdata)) {
            if(dsrdata.uint16At(DS_KEY_TAG) != keytag) continue;
            if(dsrdata.uint8At(DS_ALGORITHM) != algorithm) continue;

            var digesttype = dsrdata.uint8At(DS_DIGEST_TYPE);
            if(verifyDSHash(digesttype, keyname, keyrdata, dsrdata)) return true;
        }
        return false;
    }

    /**
     * @dev Attempts to verify a DS record's hash value against some data.
     * @param digesttype The digest ID from the DS record.
     * @param keyname The DNS name of the key, in DNS label-sequence format.
     * @param keyrdata The RDATA section of the key to verify.
     * @param digest The digest data to check against.
     * @return True if the digest matches.
     */
    function verifyDSHash(uint8 digesttype, BytesUtils.slice memory keyname, BytesUtils.slice memory keyrdata, BytesUtils.slice memory digest) internal view returns (bool) {
        if(digests[digesttype] == address(0)) return false;

        bytes memory data = new bytes(keyname.len + keyrdata.len);
        BytesUtils.slice memory dataslice;
        dataslice.fromBytes(data);
        dataslice.memcpy(0, keyname, 0, keyname.len);
        dataslice.memcpy(keyname.len, keyrdata, 0, keyrdata.len);
        return digests[digesttype].verify(dataslice.toBytes(), digest.toBytes(4, digest.len));
    }
}
