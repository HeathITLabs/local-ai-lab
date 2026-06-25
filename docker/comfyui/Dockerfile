FROM pytorch/pytorch:2.7.1-cuda12.8-cudnn9-runtime

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      git \
      curl \
      libgl1 \
      libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/comfyui-requirements.txt
RUN python -m pip install --upgrade pip \
    && python -m pip install -r /tmp/comfyui-requirements.txt

COPY . /app
RUN find /app/custom_nodes -maxdepth 2 -name requirements.txt -print \
    -exec python -m pip install -r {} \;

EXPOSE 8188

CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
