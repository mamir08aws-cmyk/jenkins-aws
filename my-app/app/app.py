from flask import Flask, jsonify
app = Flask(__name__)

@app.route("/")
def home():
    return "<h1>Hello from Jenkins-deployed AWS EC2!</h1>"

@app.route("/health")
def health():
    return jsonify({"status": "ok"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)