FROM public.ecr.aws/aws-observability/aws-for-fluent-bit:stable
COPY custom.conf /fluent-bit/etc/custom.conf
COPY parsers.conf /fluent-bit/etc/parsers.conf
COPY iceberg_transform.lua /fluent-bit/etc/iceberg_transform.lua
