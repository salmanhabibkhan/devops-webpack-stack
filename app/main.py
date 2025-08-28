from fastapi import FastAPI

app = FastAPI()

@app.get("/")
def root():
    return {"ok": True, "service": "web-api"}

@app.get("/health")
def health():
    return {"status": "healthy"}