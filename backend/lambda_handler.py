from mangum import Mangum

from server import app


# ============================================================
# AWS LAMBDA HANDLER
# ============================================================

handler = Mangum(
    app,
    lifespan="off",
)
