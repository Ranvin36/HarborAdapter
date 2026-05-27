import ballerina/http;
import ballerina/log;
import ballerina/task;
import ballerina/time;


final http:Client centralClient = check new ("https://api.central.ballerina.io");

// Isolated in-memory stores — safe for concurrent access
isolated map<BalaMetadata> digestToMetadata = {};
isolated map<byte[]> digestToRawBytes = {};
// Tracks last access time (Unix seconds) per digest for TTL-based eviction
isolated map<decimal> digestLastAccessed = {};
final string OCI_EMPTY_CONFIG_DIGEST = "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";
final decimal DIGEST_TTL_SECONDS = 10;

// Background job that evicts digests idle for more than DIGEST_TTL_SECONDS
class DigestEvictionJob {
    *task:Job;
    public function execute() {
        decimal nowSeconds = time:monotonicNow();
        map<decimal> snapshot = {};
        lock {
            snapshot = digestLastAccessed.clone();
        }
        string[] toEvict = from string digest in snapshot.keys()
                           where nowSeconds - snapshot.get(digest) > DIGEST_TTL_SECONDS
                           select digest;
        foreach string digest in toEvict {
            lock {
                _ = digestToMetadata.removeIfHasKey(digest);
            }
            lock {
                _ = digestToRawBytes.removeIfHasKey(digest);
            }
            lock {
                _ = digestLastAccessed.removeIfHasKey(digest);
            }
            log:printInfo("Evicted idle digest from memory", digest = digest);
        }
    }
}

// Touch the last-accessed timestamp for a digest
function touchDigest(string digest) {
    lock {
        digestLastAccessed[digest] = time:monotonicNow();
    }
}

// Start the eviction job — runs every 5 seconds, checks for 10s idle digests
final task:JobId evictionJobId = check task:scheduleJobRecurByFrequency(new DigestEvictionJob(), 5);

service / on new http:Listener(8080) {
    // GET /v2
    resource function get v2() returns http:Response {
        log:printInfo("Received request for /v2/");
        http:Response v2Response = new;
        v2Response.statusCode = 200;
        v2Response.setHeader("Docker-Distribution-API-Version", "2.0");
        return v2Response;
    }

    // GET /v2/{org}/{name}/manifests/latest
    resource function get v2/[string org]/[string name]/manifests/latest() returns http:Response|error {
        log:printInfo("Received GET latest manifest request", org = org, name = name);
        return buildLatestManifestResponse(org, name);
    }

    // HEAD /v2/{org}/{name}/manifests/latest — Docker clients probe with HEAD
    resource function head v2/[string org]/[string name]/manifests/latest() returns http:Response|error {
        log:printInfo("Received HEAD latest manifest request", org = org, name = name);
        return buildLatestManifestResponse(org, name);
    }

    // GET /v2/{org}/{name}/manifests/{version}
    resource function get v2/[string org]/[string name]/manifests/[string version](http:Request req) returns http:Response|error {
        log:printInfo("Received GET manifest request", org = org, name = name, version = version);
        logRequestHeaders(req);
        return buildVersionManifestResponse(org, name, version);
    }

    // HEAD /v2/{org}/{name}/manifests/{version} — Docker clients probe with HEAD
    resource function head v2/[string org]/[string name]/manifests/[string version](http:Request req) returns http:Response|error {
        log:printInfo("Received HEAD manifest request", org = org, name = name, version = version);
        logRequestHeaders(req);
        return buildVersionManifestResponse(org, name, version);
    }

    // HEAD /v2/{org}/{name}/blobs/{digest} — Docker checks blob existence before pulling
    resource function head v2/[string org]/[string name]/blobs/[string digest]() returns http:Response|error {
        log:printInfo("Received HEAD request for blob", org = org, name = name, digest = digest);
        if digest == OCI_EMPTY_CONFIG_DIGEST {
            http:Response headResponse = new;
            headResponse.statusCode = 200;
            headResponse.setHeader("Content-Type", "application/octet-stream");
            return headResponse;
        }
        boolean knownInMetadata;
        lock {
            knownInMetadata = digestToMetadata.hasKey(digest);
        }
        boolean knownInRaw;
        lock {
            knownInRaw = digestToRawBytes.hasKey(digest);
        }
        boolean knownDigest = knownInMetadata || knownInRaw;
        if knownDigest {
            http:Response headResponse = new;
            headResponse.statusCode = 200;
            headResponse.setHeader("Content-Type", "application/octet-stream");
            return headResponse;
        }
        // Digest not in memory — re-fetch metadata from Central to recover
        log:printInfo("Digest not in memory on HEAD, re-fetching from Central", digest = digest, org = org, name = name);
        string|http:Response|error fetchResult = fetchBalaFromCentral(org, name, "*");
        if fetchResult is string && fetchResult == digest {
            http:Response headResponse = new;
            headResponse.statusCode = 200;
            headResponse.setHeader("Content-Type", "application/octet-stream");
            return headResponse;
        }
        http:Response notFound = new;
        notFound.statusCode = 404;
        notFound.setHeader("Content-Type", "application/json");
        notFound.setTextPayload("{\"errors\":[{\"code\":\"BLOB_UNKNOWN\"}]}", contentType = "application/json");
        return notFound;
    }

    // GET /v2/{org}/{name}/blobs/{digest}
    resource function get v2/[string org]/[string name]/blobs/[string digest]() returns http:Response|error {
        log:printInfo("Received request for blob", org = org, name = name, digest = digest);

        if digest == OCI_EMPTY_CONFIG_DIGEST {
            http:Response configResponse = new;
            configResponse.statusCode = 200;
            configResponse.setTextPayload("{}", contentType = "application/vnd.oci.image.config.v1+json");
            return configResponse;
        }

        // Check raw bytes cache (versions JSON from latest endpoint)
        byte[]? rawBytes;
        lock {
            byte[]? rawBytesInner = digestToRawBytes[digest];
            rawBytes = rawBytesInner is byte[] ? rawBytesInner.clone() : ();
        }
        if rawBytes is byte[] {
            touchDigest(digest);
            log:printInfo("Serving raw bytes from cache", digest = digest);
            http:Response rawBlobResponse = new;
            rawBlobResponse.statusCode = 200;
            rawBlobResponse.setHeader("Content-Type", "application/octet-stream");
            rawBlobResponse.setPayload(rawBytes);
            return rawBlobResponse;
        }

        // Check bala metadata cache
        BalaMetadata? metadata;
        lock {
            BalaMetadata? metadataInner = digestToMetadata[digest];
            metadata = metadataInner is BalaMetadata ? metadataInner.clone() : ();
        }

        // Metadata missing (e.g. different pod served the manifest) — re-fetch from Central
        if metadata is () {
            log:printInfo("Digest not in memory, re-fetching metadata from Central", digest = digest, org = org, name = name);
            string|http:Response|error fetchResult = fetchBalaFromCentral(org, name, "*");
            if fetchResult is string {
                lock {
                    BalaMetadata? refetched = digestToMetadata[digest];
                    metadata = refetched is BalaMetadata ? refetched.clone() : ();
                }
            }
        }

        if metadata is () {
            log:printInfo("Digest not found after re-fetch attempt", digest = digest);
            http:Response notFound = new;
            notFound.statusCode = 404;
            notFound.setTextPayload("{\"errors\":[{\"code\":\"BLOB_UNKNOWN\"}]}", contentType = "application/json");
            return notFound;
        }

        byte[] balaBytes;
        byte[]? cached = metadata.cachedBytes;
        if cached is byte[] {
            touchDigest(digest);
            log:printInfo("Serving bala bytes from cache", digest = digest);
            balaBytes = cached;
        } else {
            log:printInfo("Fetching bala bytes on demand", digest = digest, org = metadata.org, name = metadata.name, version = metadata.version);
            http:Client balaClient = check new (metadata.balaURL);
            http:Response balaResponse = check balaClient->get("");
            balaBytes = check balaResponse.getBinaryPayload();
            BalaMetadata updatedMetadata = {
                org: metadata.org,
                name: metadata.name,
                version: metadata.version,
                balaURL: metadata.balaURL,
                cachedBytes: balaBytes.clone()
            };
            lock {
                digestToMetadata[digest] = updatedMetadata.clone();
            }
            touchDigest(digest);
            log:printInfo("Cached bala bytes for future requests", digest = digest, size = balaBytes.length());
        }

        http:Response blobResponse = new;
        blobResponse.statusCode = 200;
        blobResponse.setHeader("Content-Type", "application/octet-stream");
        blobResponse.setPayload(balaBytes);
        return blobResponse;
    }
}
