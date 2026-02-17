module.exports = {
  apps: [
    {
      name: 'adult-hockey-agent',
      script: './dist/scheduler.js',

      // Environment variables (load from .env file)
      env: {
        NODE_ENV: 'production',
      },

      // Restart configuration
      autorestart: true,
      max_restarts: 10,
      min_uptime: '10s',
      restart_delay: 4000,
      exp_backoff_restart_delay: 100,

      // Logs
      error_file: './logs/error.log',
      out_file: './logs/out.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
      merge_logs: true,

      // Performance
      watch: false,
      max_memory_restart: '500M',

      // Instance configuration
      instances: 1,
      exec_mode: 'fork',

      // Don't auto-start in cluster mode
      kill_timeout: 5000,
      wait_ready: false,
      listen_timeout: 3000,
    },
  ],
}
