import json
import boto3
import uuid
from datetime import datetime
from jinja2 import Environment, FileSystemLoader, select_autoescape
import os
from urllib.parse import parse_qs

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table("games-catalogue")

jinja_env = Environment(
    loader=FileSystemLoader(os.path.join(os.path.dirname(__file__), "templates")),
    autoescape=select_autoescape(["html", "xml"])
)


def lambda_handler(event, context):
    # Handle both Function URL format and ALB/proxy format
    if "requestContext" in event and "http" in event["requestContext"]:
        http_method = event["requestContext"]["http"]["method"]
        path = event["requestContext"]["http"]["path"]
    else:
        http_method = event.get("httpMethod", "GET")
        path = event.get("path", "/")
    
    # Strip /games prefix if present (from Nginx proxy)
    if path.startswith("/gc"):
        path = path[3:]
    if not path:
        path = "/"
    print(f"Using the path {path}")

    try:
        if http_method == "GET":
            print("GET method")
            if path == "/":
                games = get_all_games_data()
                platforms = sorted(set(g["platform"] for g in games))
                return render_html("index.html", games=games, platforms=platforms)
            elif path == "/wishlist":
                wishlist = get_wishlist_data()
                platforms = sorted(set(g["platform"] for g in wishlist))
                return render_html("wishlist.html", wishlist=wishlist, platforms=platforms)
            else:
                platform = path.lstrip("/")
                games = get_games_by_platform_data(platform)
                platforms = sorted(set(g["platform"] for g in games))
                return render_html("index.html", games=games, platforms=platforms, selected_platform=platform)

        elif http_method == "POST":
            print("POST method")
            body = {k: v[0] for k, v in parse_qs(event["body"]).items()}
            if path == "/add":
                add_game(body)
                platform = body.get("platform", "")
                redirect_url = f"/gc/{platform}" if platform else "/gc"
                return redirect_response(redirect_url)
            elif path == "/wishlist/add":
                add_to_wishlist(body)
                return redirect_response("/gc/wishlist")
            elif path == "/wishlist/purchased":
                mark_as_purchased(body)
                return redirect_response("/gc/wishlist")

        elif http_method == "DELETE":
            print("DELETE method")
            # body = json.loads(event["body"])
            body = {k: v[0] for k, v in parse_qs(event["body"]).items()}
            if path == "/delete":
                delete_game(body)
                platform = body.get("platform", "")
                redirect_url = f"/{platform}" if platform else "/"
                return redirect_response(redirect_url)
            elif path == "/wishlist/delete":
                delete_from_wishlist(body)
                return redirect_response("/wishlist")

        print("Unknown method")
        return render_html("error.html", status_code=404, message="Not found")

    except Exception as e:
        print(f"Error: {str(e)}")
        return render_html("error.html", status_code=500, message=str(e))


def get_all_games_data():
    response = table.scan(
        FilterExpression="attribute_not_exists(#s) OR #s = :owned",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":owned": "owned"}
    )
    return response.get("Items", [])


def get_games_by_platform_data(platform):
    response = table.query(
        KeyConditionExpression="platform = :platform",
        FilterExpression="attribute_not_exists(#s) OR #s = :owned",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":platform": platform, ":owned": "owned"}
    )
    return response.get("Items", [])


def get_wishlist_data():
    response = table.scan(
        FilterExpression="#s = :wishlist",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":wishlist": "wishlist"}
    )
    return response.get("Items", [])


def add_game(body):
    game_id = str(uuid.uuid4())
    platform = body.get("platform")
    game_name = body.get("game_name")
    genre = body.get("genre")
    year = body.get("year")

    if not all([platform, game_name]):
        raise ValueError("Missing required fields: platform, game_name")

    table.put_item(
        Item={
            "platform": platform,
            "game_id": game_id,
            "game_name": game_name,
            "genre": genre,
            "year": year,
            "status": "owned",
            "added_date": datetime.now().isoformat()
        }
    )


def add_to_wishlist(body):
    print(f"Adding to wishlist {body}")
    game_id = str(uuid.uuid4())
    platform = body.get("platform")
    game_name = body.get("game_name")
    genre = body.get("genre")
    year = body.get("year")
    
    if not all([platform, game_name]):
        raise ValueError("Missing required fields: platform, game_name")

    table.put_item(
        Item={
            "platform": platform,
            "game_id": game_id,
            "game_name": game_name,
            "genre": genre,
            "year": year,
            "status": "wishlist",
            "added_date": datetime.now().isoformat()
        }
    )


def delete_game(body):
    print(f"Deleting game: {body}")
    platform = body.get("platform")
    game_id = body.get("game_id")

    if not all([platform, game_id]):
        raise ValueError("Missing required fields: platform, game_id")

    table.delete_item(Key={"platform": platform, "game_id": game_id})


def delete_from_wishlist(body):
    print(f"Deleting from wishlist: {body}")
    platform = body.get("platform")
    game_id = body.get("game_id")

    if not all([platform, game_id]):
        raise ValueError("Missing required fields: platform, game_id")

    table.delete_item(Key={"platform": platform, "game_id": game_id})


def mark_as_purchased(body):
    print(f"Marking as purchased {body}")
    platform = body.get("platform")
    game_id = body.get("game_id")

    if not all([platform, game_id]):
        raise ValueError("Missing required fields: platform, game_id")

    table.update_item(
        Key={"platform": platform, "game_id": game_id},
        UpdateExpression="SET #s = :owned",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":owned": "owned"}
    )


def render_html(template_name, **kwargs):
    template = jinja_env.get_template(template_name)
    html = template.render(**kwargs)
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": html
    }


def redirect_response(location):
    return {
        "statusCode": 303,
        "headers": {"Location": location},
        "body": ""
    }