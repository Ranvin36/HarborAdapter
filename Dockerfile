# Auto Generated Dockerfile
FROM ballerina/jvm-runtime:3.1

LABEL maintainer="dev@ballerina.io"
COPY accessors-smart-2.4.7.jar /home/ballerina/jars/ 
COPY auth-native-2.14.0.jar /home/ballerina/jars/ 
COPY ballerina-auth-2.14.0.jar /home/ballerina/jars/ 
COPY ballerina-cache-3.10.0.jar /home/ballerina/jars/ 
COPY ballerina-cloud-4.0.0.jar /home/ballerina/jars/ 
COPY ballerina-constraint-1.7.0.jar /home/ballerina/jars/ 
COPY ballerina-crypto-2.12.1.jar /home/ballerina/jars/ 
COPY ballerina-data.jsondata-1.1.3.jar /home/ballerina/jars/ 
COPY ballerina-file-1.13.0.jar /home/ballerina/jars/ 
COPY ballerina-http-2.16.3.jar /home/ballerina/jars/ 
COPY ballerina-http.httpscerr-2.16.3.jar /home/ballerina/jars/ 
COPY ballerina-io-1.8.0.jar /home/ballerina/jars/ 
COPY ballerina-jwt-2.15.1.jar /home/ballerina/jars/ 
COPY ballerina-log-2.17.0.jar /home/ballerina/jars/ 
COPY ballerina-mime-2.12.1.jar /home/ballerina/jars/ 
COPY ballerina-oauth2-2.15.0.jar /home/ballerina/jars/ 
COPY ballerina-observe-1.7.1.jar /home/ballerina/jars/ 
COPY ballerina-observe.mockextension-1.7.1.jar /home/ballerina/jars/ 
COPY ballerina-os-1.10.1.jar /home/ballerina/jars/ 
COPY ballerina-rt-2201.13.2.jar /home/ballerina/jars/ 
COPY ballerina-task-2.11.1.jar /home/ballerina/jars/ 
COPY ballerina-time-2.8.0.jar /home/ballerina/jars/ 
COPY ballerina-url-2.6.1.jar /home/ballerina/jars/ 
COPY ballerina-uuid-1.10.0.jar /home/ballerina/jars/ 
COPY ballerinai-observe-0.0.0.jar /home/ballerina/jars/ 
COPY bcpg-jdk18on-1.84.jar /home/ballerina/jars/ 
COPY bcpkix-jdk18on-1.84.jar /home/ballerina/jars/ 
COPY bcprov-jdk18on-1.84.jar /home/ballerina/jars/ 
COPY bcutil-jdk18on-1.84.jar /home/ballerina/jars/ 
COPY cache-native-3.10.0.jar /home/ballerina/jars/ 
COPY commons-pool-1.5.6.wso2v1.jar /home/ballerina/jars/ 
COPY constraint-native-1.7.0.jar /home/ballerina/jars/ 
COPY crypto-native-2.12.1.jar /home/ballerina/jars/ 
COPY data.jsondata-native-1.1.3.jar /home/ballerina/jars/ 
COPY file-native-1.13.0.jar /home/ballerina/jars/ 
COPY http-native-2.16.3.jar /home/ballerina/jars/ 
COPY io-compiler-plugin-1.8.0.jar /home/ballerina/jars/ 
COPY io-native-1.8.0.jar /home/ballerina/jars/ 
COPY jakarta.activation-api-2.0.1.jar /home/ballerina/jars/ 
COPY jboss-marshalling-2.0.5.Final.jar /home/ballerina/jars/ 
COPY json-path-2.9.0.jar /home/ballerina/jars/ 
COPY json-smart-2.4.11.jar /home/ballerina/jars/ 
COPY jwt-native-2.15.1.jar /home/ballerina/jars/ 
COPY log-compiler-plugin-2.17.0.jar /home/ballerina/jars/ 
COPY log-native-2.17.0.jar /home/ballerina/jars/ 
COPY lz4-java-1.10.1.jar /home/ballerina/jars/ 
COPY mime-native-2.12.1.jar /home/ballerina/jars/ 
COPY mimepull-1.9.11.jar /home/ballerina/jars/ 
COPY netty-buffer-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-codec-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-codec-http-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-codec-http2-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-codec-socks-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-common-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-handler-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-handler-proxy-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-resolver-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-tcnative-boringssl-static-2.0.77.Final-linux-aarch_64.jar /home/ballerina/jars/ 
COPY netty-tcnative-boringssl-static-2.0.77.Final-linux-x86_64.jar /home/ballerina/jars/ 
COPY netty-tcnative-boringssl-static-2.0.77.Final-osx-aarch_64.jar /home/ballerina/jars/ 
COPY netty-tcnative-boringssl-static-2.0.77.Final-osx-x86_64.jar /home/ballerina/jars/ 
COPY netty-tcnative-boringssl-static-2.0.77.Final-windows-x86_64.jar /home/ballerina/jars/ 
COPY netty-tcnative-boringssl-static-2.0.77.Final.jar /home/ballerina/jars/ 
COPY netty-tcnative-classes-2.0.77.Final.jar /home/ballerina/jars/ 
COPY netty-transport-4.1.133.Final.jar /home/ballerina/jars/ 
COPY netty-transport-native-unix-common-4.1.133.Final.jar /home/ballerina/jars/ 
COPY oauth2-native-2.15.0.jar /home/ballerina/jars/ 
COPY observe-internal-native-1.7.1.jar /home/ballerina/jars/ 
COPY observe-native-1.7.1.jar /home/ballerina/jars/ 
COPY opentelemetry-sdk-common-1.0.0.jar /home/ballerina/jars/ 
COPY opentelemetry-sdk-testing-1.0.0.jar /home/ballerina/jars/ 
COPY opentelemetry-sdk-trace-1.0.0.jar /home/ballerina/jars/ 
COPY opentelemetry-semconv-1.0.0-alpha.jar /home/ballerina/jars/ 
COPY org.wso2.transport.local-file-system-6.0.55.jar /home/ballerina/jars/ 
COPY os-compiler-plugin-1.10.1.jar /home/ballerina/jars/ 
COPY os-native-1.10.1.jar /home/ballerina/jars/ 
COPY os-test-utils-1.10.1.jar /home/ballerina/jars/ 
COPY protobuf-java-3.25.5.jar /home/ballerina/jars/ 
COPY quartz-2.3.2.jar /home/ballerina/jars/ 
COPY task-native-2.11.1.jar /home/ballerina/jars/ 
COPY time-native-2.8.0.jar /home/ballerina/jars/ 
COPY url-native-2.6.1.jar /home/ballerina/jars/ 
COPY ranvin-HarborAdapter-0.1.0.jar /home/ballerina/jars/ 
RUN addgroup troupe \
    && adduser -S -s /bin/bash -g 'ballerina' -G troupe -D ballerina \
    && apk add --update --no-cache bash \
    && rm -rf /var/cache/apk/*

WORKDIR /home/ballerina

EXPOSE 9090
USER ballerina

ENTRYPOINT ["java","-XX:+ExitOnOutOfMemoryError","-Xdiag","-cp","ranvin-HarborAdapter-0.1.0.jar:jars/*","ranvin.HarborAdapter.0.$_init"]
