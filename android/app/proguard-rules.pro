# ZEON application-specific R8 rules.
#
# Deliberately empty: generated Flutter plugin registration, MethodChannel
# handlers, gomobile/JNI and serialization are covered by direct references or
# dependency consumer rules. Do not add package-wide keep rules here. Any future
# rule must name its reflection/JNI/serialization owner and have a release test.
