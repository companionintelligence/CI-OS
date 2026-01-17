# Cloud API Implementation Guide

This document provides a reference implementation guide for the cloud API endpoints required to support the headless Wi-Fi provisioning system.

## Overview

The cloud API facilitates the token-based pairing mechanism that securely associates devices with user accounts without transmitting user credentials to the device.

## Technology Stack Recommendations

- **Framework**: Express.js (Node.js), Flask (Python), or FastAPI (Python)
- **Database**: PostgreSQL, MySQL, or MongoDB
- **Authentication**: JWT (JSON Web Tokens)
- **Rate Limiting**: Redis-based rate limiter
- **API Documentation**: OpenAPI/Swagger

## Database Schema

### Users Table

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### Devices Table

```sql
CREATE TABLE devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    mac_address VARCHAR(17) UNIQUE NOT NULL,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    auth_secret TEXT,
    firmware_version VARCHAR(50),
    ip_address VARCHAR(45),
    last_seen TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_devices_user_id ON devices(user_id);
CREATE INDEX idx_devices_mac_address ON devices(mac_address);
```

### Pairing Tokens Table

```sql
CREATE TABLE pairing_tokens (
    token VARCHAR(6) PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    used BOOLEAN DEFAULT FALSE,
    used_at TIMESTAMP
);

CREATE INDEX idx_pairing_tokens_user_id ON pairing_tokens(user_id);
CREATE INDEX idx_pairing_tokens_expires_at ON pairing_tokens(expires_at);
```

## API Endpoints

### 1. Generate Pairing Token

**Endpoint**: `POST /api/v1/provisioning/tokens`

**Authentication**: Required (User JWT)

**Description**: Generates a new random 6-character alphanumeric token for device pairing.

**Request Headers**:
```
Authorization: Bearer {user_jwt}
Content-Type: application/json
```

**Response (201 Created)**:
```json
{
  "token": "XY78K2",
  "expires_at": "2026-01-17T15:00:00Z",
  "ttl_seconds": 900
}
```

**Error Responses**:
- `401 Unauthorized`: Invalid or missing authentication token
- `429 Too Many Requests`: Rate limit exceeded (max 10 tokens/hour per user)
- `500 Internal Server Error`: Server error

**Implementation Example (Python/Flask)**:

```python
from flask import Blueprint, request, jsonify
from datetime import datetime, timedelta
import random
import string

provisioning_bp = Blueprint('provisioning', __name__)

def generate_token():
    """Generate a random 6-character alphanumeric token"""
    chars = string.ascii_uppercase + string.digits
    return ''.join(random.choices(chars, k=6))

@provisioning_bp.route('/api/v1/provisioning/tokens', methods=['POST'])
@require_auth  # Custom decorator for JWT validation
def create_pairing_token():
    user_id = request.user_id  # Extracted from JWT
    
    # Rate limiting check
    if not check_rate_limit(user_id, 'token_generation', max_requests=10, window=3600):
        return jsonify({'error': 'Rate limit exceeded'}), 429
    
    # Generate unique token
    max_attempts = 10
    for _ in range(max_attempts):
        token = generate_token()
        if not db.query('SELECT 1 FROM pairing_tokens WHERE token = %s', (token,)):
            break
    else:
        return jsonify({'error': 'Failed to generate unique token'}), 500
    
    # Calculate expiry (15 minutes)
    expires_at = datetime.utcnow() + timedelta(minutes=15)
    
    # Store token
    db.execute(
        'INSERT INTO pairing_tokens (token, user_id, expires_at) VALUES (%s, %s, %s)',
        (token, user_id, expires_at)
    )
    
    return jsonify({
        'token': token,
        'expires_at': expires_at.isoformat() + 'Z',
        'ttl_seconds': 900
    }), 201
```

### 2. Claim Device (Pairing)

**Endpoint**: `POST /api/v1/devices/claim`

**Authentication**: Public (Authorized via pairing token)

**Description**: Device submits pairing token and hardware information to associate with user account.

**Request Body**:
```json
{
  "pairing_token": "XY78K2",
  "mac_address": "aa:bb:cc:dd:ee:ff",
  "firmware_version": "1.0.0",
  "ip_address": "203.0.113.55"
}
```

**Response (200 OK)**:
```json
{
  "status": "success",
  "device_id": "12345678-abcd-1234-abcd-1234567890ab",
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "mqtt_endpoint": "mqtts://iot-hub.example.com:8883",
  "mqtt_topic": "devices/12345678-abcd-1234-abcd-1234567890ab"
}
```

**Error Responses**:
- `400 Bad Request`: Invalid request format or missing required fields
- `404 Not Found`: Token not found
- `410 Gone`: Token expired
- `429 Too Many Requests`: Rate limit exceeded
- `500 Internal Server Error`: Server error

**Implementation Example (Python/Flask)**:

```python
import jwt
import secrets

@provisioning_bp.route('/api/v1/devices/claim', methods=['POST'])
def claim_device():
    data = request.get_json()
    
    # Validate input
    required_fields = ['pairing_token', 'mac_address']
    if not all(field in data for field in required_fields):
        return jsonify({'error': 'Missing required fields'}), 400
    
    pairing_token = data['pairing_token'].upper()
    mac_address = data['mac_address'].lower()
    firmware_version = data.get('firmware_version', 'unknown')
    ip_address = data.get('ip_address', 'unknown')
    
    # Rate limiting by MAC address
    if not check_rate_limit(mac_address, 'device_claim', max_requests=5, window=3600):
        return jsonify({'error': 'Rate limit exceeded'}), 429
    
    # Lookup token
    token_data = db.query_one(
        '''SELECT token, user_id, expires_at, used 
           FROM pairing_tokens 
           WHERE token = %s''',
        (pairing_token,)
    )
    
    if not token_data:
        return jsonify({'error': 'Invalid pairing token'}), 404
    
    # Check if token is expired
    if datetime.utcnow() > token_data['expires_at']:
        return jsonify({'error': 'Pairing token expired'}), 410
    
    # Check if token already used
    if token_data['used']:
        return jsonify({'error': 'Pairing token already used'}), 400
    
    user_id = token_data['user_id']
    
    # Check if device already exists
    device = db.query_one(
        'SELECT id, user_id FROM devices WHERE mac_address = %s',
        (mac_address,)
    )
    
    if device:
        # Update existing device
        device_id = device['id']
        db.execute(
            '''UPDATE devices 
               SET user_id = %s, firmware_version = %s, ip_address = %s, 
                   last_seen = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
               WHERE id = %s''',
            (user_id, firmware_version, ip_address, device_id)
        )
    else:
        # Create new device
        device_id = str(uuid.uuid4())
        auth_secret = secrets.token_urlsafe(32)
        
        db.execute(
            '''INSERT INTO devices 
               (id, mac_address, user_id, auth_secret, firmware_version, ip_address)
               VALUES (%s, %s, %s, %s, %s, %s)''',
            (device_id, mac_address, user_id, auth_secret, firmware_version, ip_address)
        )
    
    # Mark token as used
    db.execute(
        '''UPDATE pairing_tokens 
           SET used = TRUE, used_at = CURRENT_TIMESTAMP 
           WHERE token = %s''',
        (pairing_token,)
    )
    
    # Generate device access token (JWT)
    device_token = jwt.encode(
        {
            'device_id': device_id,
            'mac_address': mac_address,
            'user_id': user_id,
            'iat': datetime.utcnow(),
            'exp': datetime.utcnow() + timedelta(days=365)  # 1 year expiry
        },
        app.config['JWT_SECRET'],
        algorithm='HS256'
    )
    
    # Return success response
    return jsonify({
        'status': 'success',
        'device_id': device_id,
        'access_token': device_token,
        'mqtt_endpoint': app.config['MQTT_ENDPOINT'],
        'mqtt_topic': f'devices/{device_id}'
    }), 200
```

### 3. Check Pairing Status

**Endpoint**: `GET /api/v1/provisioning/status/{token}`

**Authentication**: Required (User JWT)

**Description**: Check if a pairing token has been used to claim a device. Useful for dashboard UI to auto-refresh when pairing completes.

**Request Headers**:
```
Authorization: Bearer {user_jwt}
```

**Response (200 OK - Token Used)**:
```json
{
  "status": "paired",
  "device": {
    "id": "12345678-abcd-1234-abcd-1234567890ab",
    "mac_address": "aa:bb:cc:dd:ee:ff",
    "paired_at": "2026-01-17T14:55:00Z"
  }
}
```

**Response (200 OK - Token Not Used)**:
```json
{
  "status": "pending",
  "expires_at": "2026-01-17T15:00:00Z"
}
```

**Error Responses**:
- `401 Unauthorized`: Invalid authentication
- `403 Forbidden`: Token belongs to different user
- `404 Not Found`: Token not found

**Implementation Example**:

```python
@provisioning_bp.route('/api/v1/provisioning/status/<token>', methods=['GET'])
@require_auth
def check_pairing_status(token):
    user_id = request.user_id
    
    # Lookup token
    token_data = db.query_one(
        '''SELECT t.token, t.user_id, t.expires_at, t.used, t.used_at,
                  d.id as device_id, d.mac_address
           FROM pairing_tokens t
           LEFT JOIN devices d ON d.user_id = t.user_id 
                               AND d.updated_at >= t.created_at
           WHERE t.token = %s''',
        (token.upper(),)
    )
    
    if not token_data:
        return jsonify({'error': 'Token not found'}), 404
    
    # Verify token belongs to requesting user
    if token_data['user_id'] != user_id:
        return jsonify({'error': 'Access denied'}), 403
    
    if token_data['used'] and token_data['device_id']:
        return jsonify({
            'status': 'paired',
            'device': {
                'id': token_data['device_id'],
                'mac_address': token_data['mac_address'],
                'paired_at': token_data['used_at'].isoformat() + 'Z'
            }
        }), 200
    else:
        return jsonify({
            'status': 'pending',
            'expires_at': token_data['expires_at'].isoformat() + 'Z'
        }), 200
```

## Rate Limiting Implementation

**Redis-based rate limiter**:

```python
import redis
from functools import wraps

redis_client = redis.Redis(host='localhost', port=6379, db=0)

def check_rate_limit(identifier, action, max_requests, window):
    """
    Check if the rate limit has been exceeded.
    
    Args:
        identifier: Unique identifier (user_id, MAC address, IP)
        action: Action name (e.g., 'token_generation', 'device_claim')
        max_requests: Maximum number of requests allowed
        window: Time window in seconds
    
    Returns:
        True if request is allowed, False if rate limit exceeded
    """
    key = f'rate_limit:{action}:{identifier}'
    
    current = redis_client.get(key)
    
    if current is None:
        # First request
        redis_client.setex(key, window, 1)
        return True
    
    current = int(current)
    
    if current >= max_requests:
        return False
    
    redis_client.incr(key)
    return True
```

## Security Best Practices

### 1. Token Generation
- Use cryptographically secure random number generator
- Ensure uniqueness (check database before insertion)
- Limit token lifetime (15 minutes recommended)
- Implement one-time use (invalidate after successful pairing)

### 2. Rate Limiting
- **Token Generation**: 10 tokens per hour per user
- **Device Claiming**: 5 attempts per hour per MAC address
- **Global Limit**: 1000 token generations per day per user (prevent abuse)

### 3. Input Validation
- Validate MAC address format (aa:bb:cc:dd:ee:ff)
- Sanitize all user inputs
- Enforce token format (6 alphanumeric characters)
- Validate firmware version string

### 4. HTTPS Enforcement
- All endpoints must use HTTPS/TLS 1.2+
- Implement HSTS (HTTP Strict Transport Security)
- Use strong cipher suites

### 5. Database Security
- Use parameterized queries (prevent SQL injection)
- Encrypt auth_secret in database
- Implement database connection pooling
- Regular backups

### 6. Logging & Monitoring
- Log all pairing attempts (success and failure)
- Monitor for suspicious patterns (rapid token generation, failed pairings)
- Alert on rate limit violations
- Track token usage metrics

## Token Cleanup

Implement a background job to clean up expired tokens:

```python
from datetime import datetime

def cleanup_expired_tokens():
    """Remove expired and unused tokens (run hourly)"""
    db.execute(
        '''DELETE FROM pairing_tokens 
           WHERE expires_at < CURRENT_TIMESTAMP 
           AND used = FALSE'''
    )
    
    # Also remove old used tokens (keep for 30 days for audit)
    db.execute(
        '''DELETE FROM pairing_tokens 
           WHERE used = TRUE 
           AND used_at < CURRENT_TIMESTAMP - INTERVAL '30 days' '''
    )
```

**Cron job**:
```bash
# Clean up expired tokens every hour
0 * * * * /usr/bin/python3 /path/to/cleanup_tokens.py
```

## Testing

### Unit Tests

```python
import unittest

class TestProvisioningAPI(unittest.TestCase):
    
    def test_generate_token_success(self):
        # Test successful token generation
        response = self.client.post(
            '/api/v1/provisioning/tokens',
            headers={'Authorization': f'Bearer {self.user_token}'}
        )
        self.assertEqual(response.status_code, 201)
        data = response.get_json()
        self.assertIn('token', data)
        self.assertEqual(len(data['token']), 6)
    
    def test_claim_device_success(self):
        # Generate token
        token = self.create_token()
        
        # Claim device
        response = self.client.post(
            '/api/v1/devices/claim',
            json={
                'pairing_token': token,
                'mac_address': 'aa:bb:cc:dd:ee:ff',
                'firmware_version': '1.0.0'
            }
        )
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data['status'], 'success')
        self.assertIn('device_id', data)
        self.assertIn('access_token', data)
    
    def test_claim_device_expired_token(self):
        # Create expired token
        token = self.create_expired_token()
        
        response = self.client.post(
            '/api/v1/devices/claim',
            json={
                'pairing_token': token,
                'mac_address': 'aa:bb:cc:dd:ee:ff'
            }
        )
        self.assertEqual(response.status_code, 410)
    
    def test_rate_limiting(self):
        # Test rate limiting on token generation
        for i in range(11):
            response = self.client.post(
                '/api/v1/provisioning/tokens',
                headers={'Authorization': f'Bearer {self.user_token}'}
            )
            if i < 10:
                self.assertEqual(response.status_code, 201)
            else:
                self.assertEqual(response.status_code, 429)
```

## Deployment Considerations

### Environment Variables

```bash
# .env file
DATABASE_URL=postgresql://user:pass@localhost/cios_db
JWT_SECRET=your-secret-key-here
REDIS_URL=redis://localhost:6379/0
MQTT_ENDPOINT=mqtts://iot-hub.example.com:8883
API_PORT=8000
ENVIRONMENT=production
```

### Docker Deployment

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

EXPOSE 8000

CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:8000", "app:app"]
```

### Load Balancing

For high availability:
- Deploy behind nginx or HAProxy
- Use multiple application servers
- Implement sticky sessions (for WebSocket connections)
- Use Redis for shared session storage

## Monitoring & Metrics

Track the following metrics:

- **Token Generation Rate**: Tokens/minute, tokens/hour
- **Pairing Success Rate**: Successful pairings / total attempts
- **Token Expiry Rate**: Expired tokens / total tokens
- **Average Pairing Time**: Time from token generation to device claim
- **Failed Pairing Reasons**: Invalid token, expired token, rate limit
- **Active Devices**: Total devices, devices per user

**Prometheus metrics example**:

```python
from prometheus_client import Counter, Histogram

token_generation_counter = Counter(
    'pairing_tokens_generated_total',
    'Total pairing tokens generated'
)

device_claim_counter = Counter(
    'device_claims_total',
    'Total device claim attempts',
    ['status']  # success, failed, expired
)

pairing_duration = Histogram(
    'pairing_duration_seconds',
    'Time from token generation to device claim'
)
```

## Support & Maintenance

- **API Versioning**: Use `/api/v1/` prefix for version control
- **Deprecation Policy**: Maintain old versions for 6 months
- **Documentation**: Keep OpenAPI/Swagger docs up to date
- **Changelog**: Document all API changes

---

**Version**: 1.0.0  
**Last Updated**: 2026-01-17  
**Maintainer**: CI-OS Team
