FROM python:3.13-slim@sha256:09a17cad02668ae61ece136b4fd36ac3849e14f670ebedb637ea3e15580525bc AS build
WORKDIR /src
COPY requirements.txt app.py ./
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt \
    && python -m compileall -b -q /src

FROM python:3.13-slim@sha256:09a17cad02668ae61ece136b4fd36ac3849e14f670ebedb637ea3e15580525bc
ARG APP_VERSION=1.0.0
ARG READY_DEFAULT=true
ARG REVISION=dev
LABEL org.opencontainers.image.title="campus-api" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${REVISION}"
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build /wheels /tmp/wheels
RUN if ls /tmp/wheels/*.whl >/dev/null 2>&1; then pip install --no-cache-dir /tmp/wheels/*.whl; fi \
    && rm -rf /tmp/wheels
COPY --from=build --chown=10001:10001 /src/app.py /app/app.py
ENV APP_VERSION=${APP_VERSION} \
    READY=${READY_DEFAULT} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080
USER 10001
EXPOSE 8080
ENTRYPOINT ["python", "/app/app.py"]
