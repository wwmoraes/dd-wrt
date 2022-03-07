#!/usr/bin/env sh

: "${WORKDIR:=build}"

SOURCES="${WORKDIR}/sources"
HOSTS="${WORKDIR}/hosts"

mkdir -p "${SOURCES}"
while IFS= read -r SOURCE; do
  TARGET=$(echo "${SOURCE}" | md5sum | cut -d' ' -f1)

  echo "checking cache for ${SOURCE} (${TARGET})"
  if [ -f "${SOURCES}/${TARGET}" ]; then
    continue
  fi

  echo "downloading ${SOURCE} (${TARGET})"
  curl -fsSLo "${SOURCES}/${TARGET}" "${SOURCE}"
done < "hosts.txt"

while IFS= read -r SOURCE; do
  TARGET=$(echo "${SOURCE}" | md5sum | cut -d' ' -f1)

  echo "checking cache for ${SOURCE} (${TARGET})"
  if [ -f "${SOURCES}/${TARGET}" ]; then
    continue
  fi

  echo "downloading ${SOURCE} (${TARGET})"
  curl -fsSL "${SOURCE}" | awk '{ print "0.0.0.0 " $0; }' > "${SOURCES}/${TARGET}"
done < "adblock.txt"

echo "extracting hosts entries..."
echo "0.0.0.0 0.0.0.0" > "${HOSTS}"
for SOURCE in "${SOURCES}"/*; do
  grep -E "^0\.0\.0\.0 .+" "${SOURCE}" |\
    grep -vE ".* 0\.0\.0\.0$" |\
    sed 's/#.*//g' >> "${HOSTS}"
done

echo "tidying up hosts..."
sort -u "${HOSTS}" | sponge "${HOSTS}"

echo "done!"
