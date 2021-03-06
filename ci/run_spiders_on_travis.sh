#!/usr/bin/env bash

if [ -f $S3_BUCKET ]; then
    (>&2 echo "Please set S3_BUCKET environment variable")
    exit 1
fi

TMPFILE=$(mktemp)
RUN_TIMESTAMP=$(date -u +%s)
RUN_S3_KEY_PREFIX="runs/${RUN_TIMESTAMP}"
RUN_S3_PREFIX="s3://${S3_BUCKET}/${RUN_S3_KEY_PREFIX}"
RUN_URL_PREFIX="https://s3.amazonaws.com/${S3_BUCKET}/${RUN_S3_KEY_PREFIX}"

cat << EOF >> $TMPFILE
<!DOCTYPE html>
<html>
<head>
</head>

<body>
<h1>Travis build ${TRAVIS_JOB_NUMBER}</h1>
<table>
    <tr>
        <th>
        Spider
        </th>
        <th>
        Results
        </th>
        <th>
        Log
        </th>
    </tr>
EOF

case "$TRAVIS_EVENT_TYPE" in
    "cron" | "api")
        SPIDERS=$(find locations/spiders -type f -name "[a-z][a-z_]*.py")
        ;;
    "push" | "pull_request")
        SPIDERS=$(git diff --name-only HEAD..$TRAVIS_BRANCH | grep 'locations/spiders')
        ;;
    *)
        echo "Unknown event type ${TRAVIS_EVENT_TYPE}"
        exit 1
        ;;
esac

for spider in $SPIDERS
do
    (>&2 echo "${spider} running ...")
    SPIDER_RUN_DIR=$(./ci/run_one_spider.sh $spider)

    if [ ! $? -eq 0 ]; then
        (>&2 echo "${spider} exited with non-zero status code")
    fi

    LOGFILE="${SPIDER_RUN_DIR}/log.txt"
    OUTFILE="${SPIDER_RUN_DIR}/output.geojson"
    TIMESTAMP=$(date -u +%F-%H-%M-%S)
    SPIDER_NAME=$(basename $spider)
    SPIDER_NAME=${SPIDER_NAME%.py}
    S3_KEY_PREFIX="results/${SPIDER_NAME}/${TIMESTAMP}"
    S3_URL_PREFIX="s3://${S3_BUCKET}/${S3_KEY_PREFIX}"
    HTTP_URL_PREFIX="https://s3.amazonaws.com/${S3_BUCKET}/${S3_KEY_PREFIX}"

    gzip < $LOGFILE > ${LOGFILE}.gz

    aws s3 cp --quiet \
        --acl=public-read \
        --content-type "text/plain; charset=utf-8" \
        --content-encoding "gzip" \
        "${LOGFILE}.gz" \
        "${S3_URL_PREFIX}/log.txt"

    if [ ! $? -eq 0 ]; then
        (>&2 echo "${spider} couldn't save logfile to s3")
        exit 1
    fi

    FEATURE_COUNT=$(wc -l < ${OUTFILE} | tr -d ' ')

    if grep -q 'Stored geojson feed' $LOGFILE; then
        gzip < $OUTFILE > ${OUTFILE}.gz

        echo "${spider} has ${FEATURE_COUNT} features"

        aws s3 cp --quiet \
            --acl=public-read \
            --content-type "application/json" \
            --content-encoding "gzip" \
            "${OUTFILE}.gz" \
            "${S3_URL_PREFIX}/output.geojson"

        if [ ! $? -eq 0 ]; then
            (>&2 echo "${spider} couldn't save output to s3")
            exit 1
        fi
    fi

    cat << EOF >> $TMPFILE
    <tr>
        <td>
        <a href="https://github.com/${TRAVIS_REPO_SLUG}/blob/${TRAVIS_COMMIT}/${spider}"><code>${spider}</code></a>
        </td>
        <td>
        <a href="${HTTP_URL_PREFIX}/output.geojson">${FEATURE_COUNT} results</a>
        (<a href="https://s3.amazonaws.com/${S3_BUCKET}/map.html?show=${HTTP_URL_PREFIX}/output.geojson">Map</a>)
        </td>
        <td>
        <a href="${HTTP_URL_PREFIX}/log.txt">Log</a>
        </td>
    </tr>
EOF

    (>&2 echo "${spider} done")
done

cat << EOF >> $TMPFILE
</table>
</body>
</html>
EOF

if [ -z "$SPIDERS" ]; then
    echo "No spiders run"
    exit 0
fi

aws s3 cp --quiet \
    --acl=public-read \
    --content-type "text/html" \
    ${TMPFILE} \
    "${RUN_S3_PREFIX}.html"

RUN_HTTP_URL="https://s3.amazonaws.com/${S3_BUCKET}/$"

if [ ! $? -eq 0 ]; then
    echo "Couldn't send run HTML to S3"
    exit 1
fi

if [ -z "$GITHUB_TOKEN" ]; then
    echo "No GITHUB_TOKEN set"
else
    if [ "$TRAVIS_PULL_REQUEST" != "false" ]; then
        curl \
            -s \
            -XPOST \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -d "{\"body\":\"Finished a build of the following spiders:\n\n\`\`\`${SPIDERS}\`\`\`\n\n${RUN_URL_PREFIX}.html\"}" \
            "https://api.github.com/repos/${TRAVIS_REPO_SLUG}/issues/${TRAVIS_PULL_REQUEST}/comments"
        echo "Added a comment to pull https://github.com/${TRAVIS_REPO_SLUG}/pull/${TRAVIS_PULL_REQUEST}"
    else
        echo "Not posting to GitHub because no pull TRAVIS_PULL_REQUEST set"
    fi
fi
