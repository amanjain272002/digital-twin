import os
import shutil
import zipfile
import subprocess


PACKAGE_DIR = "lambda-package"
ZIP_FILE = "lambda-deployment.zip"


def run_command(command):
    print("")
    print("Running:")
    print(" ".join(command))
    print("")

    result = subprocess.run(
        command,
        check=False
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"Command failed with exit code {result.returncode}"
        )


def main():

    print("========================================")
    print("Creating Lambda deployment package")
    print("========================================")

    # ========================================================
    # CLEAN
    # ========================================================

    if os.path.exists(PACKAGE_DIR):

        shutil.rmtree(
            PACKAGE_DIR
        )

    if os.path.exists(ZIP_FILE):

        os.remove(
            ZIP_FILE
        )

    os.makedirs(
        PACKAGE_DIR
    )

    # ========================================================
    # VALIDATE FILES
    # ========================================================

    required_files = [
        "server.py",
        "lambda_handler.py",
        "context.py",
        "requirements.txt"
    ]

    for filename in required_files:

        if not os.path.exists(filename):

            raise FileNotFoundError(
                f"Required backend file not found: {filename}"
            )

    # ========================================================
    # INSTALL LAMBDA DEPENDENCIES
    # ========================================================

    print("")
    print("Installing dependencies for Lambda...")
    print("")

    docker_command = [

        "docker",
        "run",

        "--rm",

        "-v",
        f"{os.getcwd()}:/var/task",

        "--platform",
        "linux/amd64",

        "--entrypoint",
        "",

        "public.ecr.aws/lambda/python:3.12",

        "/bin/sh",
        "-c",

        (
            "python -m pip install "
            "--upgrade "
            "--target /var/task/lambda-package "
            "-r /var/task/requirements.txt "
            "--platform manylinux2014_x86_64 "
            "--only-binary=:all:"
        )
    ]

    run_command(
        docker_command
    )

    # ========================================================
    # COPY APPLICATION FILES
    # ========================================================

    print("")
    print("Copying application files...")
    print("")

    application_files = [
        "server.py",
        "lambda_handler.py",
        "context.py"
    ]

    optional_files = [
        "resources.py"
    ]

    for filename in application_files:

        shutil.copy2(
            filename,
            PACKAGE_DIR
        )

    for filename in optional_files:

        if os.path.exists(filename):

            shutil.copy2(
                filename,
                PACKAGE_DIR
            )

    # ========================================================
    # COPY DATA
    # ========================================================

    if os.path.exists("data"):

        shutil.copytree(
            "data",
            os.path.join(
                PACKAGE_DIR,
                "data"
            )
        )

    # ========================================================
    # CREATE ZIP
    # ========================================================

    print("")
    print("Creating Lambda ZIP...")
    print("")

    with zipfile.ZipFile(
        ZIP_FILE,
        "w",
        zipfile.ZIP_DEFLATED
    ) as zipf:

        for root, dirs, files in os.walk(
            PACKAGE_DIR
        ):

            # Remove unnecessary Python cache folders
            dirs[:] = [
                d
                for d in dirs
                if d != "__pycache__"
            ]

            for filename in files:

                if filename.endswith(
                    (".pyc", ".pyo")
                ):
                    continue

                file_path = os.path.join(
                    root,
                    filename
                )

                arcname = os.path.relpath(
                    file_path,
                    PACKAGE_DIR
                )

                zipf.write(
                    file_path,
                    arcname
                )

    # ========================================================
    # SIZE
    # ========================================================

    size_mb = (
        os.path.getsize(ZIP_FILE)
        /
        (1024 * 1024)
    )

    print("")
    print("========================================")
    print("Lambda package created")
    print("========================================")
    print(
        f"ZIP: {ZIP_FILE}"
    )
    print(
        f"Size: {size_mb:.2f} MB"
    )
    print("========================================")


if __name__ == "__main__":

    main()
