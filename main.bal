import ballerina/http;
import ballerina/log;

listener http:Listener ep = check new http:Listener(8080);

final http:Client centralClient = check new ("https://api.central.ballerina.io");

// In-memory store mapping digest -> blob bytes (for blob retrieval)
map<byte[]> digestToBlobContent = {};
final string OCI_EMPTY_CONFIG_DIGEST = "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";

service /v2 on ep {

    // GET /v2
    resource function get .() returns http:Response {
        log:printInfo("Received request for /v2/");
        http:Response v2Response = new;
        v2Response.statusCode = 200;
        v2Response.setHeader("Docker-Distribution-API-Version", "2.0");
        return v2Response;
    }

    // HEAD /v2 — Docker clients probe with HEAD before GET
    resource function head .() returns http:Response {
        log:printInfo("Received HEAD request for /v2/");
        http:Response v2Response = new;
        v2Response.statusCode = 200;
        v2Response.setHeader("Docker-Distribution-API-Version", "2.0");
        return v2Response;
    }

    // GET /v2/{org}/{name}/manifests/latest
    resource function get [string org]/[string name]/manifests/latest() returns http:Response|error {
        log:printInfo("Received GET latest manifest request", org = org, name = name);
        return buildLatestManifestResponse(org, name);
    }

    // HEAD /v2/{org}/{name}/manifests/latest — Docker clients probe with HEAD
    resource function head [string org]/[string name]/manifests/latest() returns http:Response|error {
        log:printInfo("Received HEAD latest manifest request", org = org, name = name);
        return buildLatestManifestResponse(org, name);
    }

    // GET /v2/{org}/{name}/manifests/{version}
    resource function get [string org]/[string name]/manifests/[string version](http:Request req) returns http:Response|error {
        log:printInfo("Received GET manifest request", org = org, name = name, version = version);
        logRequestHeaders(req);
        return buildVersionManifestResponse(org, name, version);
    }

    // HEAD /v2/{org}/{name}/manifests/{version} — Docker clients probe with HEAD
    resource function head [string org]/[string name]/manifests/[string version](http:Request req) returns http:Response|error {
        log:printInfo("Received HEAD manifest request", org = org, name = name, version = version);
        logRequestHeaders(req);
        return buildVersionManifestResponse(org, name, version);
    }

    // HEAD /v2/{org}/{name}/blobs/{digest} — Docker checks blob existence before pulling
    resource function head [string org]/[string name]/blobs/[string... digestParts]() returns http:Response {
        log:printInfo("Received HEAD request for blob existence check", org = org, name = name, digestParts = digestParts);
        string digest = "";
        foreach string part in digestParts {
            digest = digest == "" ? part : digest + "/" + part;
        }
        log:printInfo("Received HEAD request for blob", org = org, name = name, digest = digest);
        if digest == OCI_EMPTY_CONFIG_DIGEST || digestToBlobContent.hasKey(digest) {
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
    resource function get [string org]/[string name]/blobs/[string... digestParts]() returns http:Response {
        log:printInfo("Received HEAD request for blob existence check", org = org, name = name, digestParts = digestParts);
        string digest = "";
        foreach string part in digestParts {
            digest = digest == "" ? part : digest + "/" + part;
        }
        log:printInfo("Received request for blob", org = org, name = name, digest = digest);

        if digest == OCI_EMPTY_CONFIG_DIGEST {
            log:printInfo("Serving dummy OCI config layer container definition", digest = digest);
            http:Response configResponse = new;
            configResponse.statusCode = 200;
            configResponse.setHeader("Content-Type", "application/vnd.oci.image.config.v1+json");
            configResponse.setTextPayload("{}", contentType = "application/vnd.oci.image.config.v1+json");
            return configResponse;
        }

        byte[]? dynamicBlobBytes = digestToBlobContent[digest];
        if dynamicBlobBytes is () {
            log:printInfo("Digest hash not found in memory map", digest = digest);
            http:Response notFound = new;
            notFound.statusCode = 404;
            notFound.setHeader("Content-Type", "application/json");
            notFound.setTextPayload("{\"errors\":[{\"code\":\"BLOB_UNKNOWN\"}]}", contentType = "application/json");
            return notFound;
        }

        http:Response blobResponse = new;
        blobResponse.statusCode = 200;
        blobResponse.setHeader("Content-Type", "application/octet-stream");
        log:printInfo("Match found, streaming bala bytes back to Harbor", digest = digest);
        blobResponse.setPayload(dynamicBlobBytes);
        return blobResponse;
    }
}
