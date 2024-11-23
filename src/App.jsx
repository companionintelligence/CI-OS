import React, { useState, useEffect } from 'react';
import Login from './Login';
import Dashboard from './Dashboard';

const App = () => {
  const [token, setToken] = useState(null);
  const [darkMode, setDarkMode] = useState(false);

  useEffect(() => {
    const savedToken = localStorage.getItem('token');
    if (savedToken) {
      setToken(savedToken);
    }
    const savedMode = localStorage.getItem('darkMode') === 'true';
    setDarkMode(savedMode);
    document.documentElement.classList.toggle('dark', savedMode);
  }, []);

  const handleLogin = (token) => {
    localStorage.setItem('token', token);
    setToken(token);
  };

  const handleLogout = () => {
    localStorage.removeItem('token');
    setToken(null);
  };

  const toggleDarkMode = () => {
    const newMode = !darkMode;
    setDarkMode(newMode);
    localStorage.setItem('darkMode', newMode);
    document.documentElement.classList.toggle('dark', newMode);
  };

  return (
    <div className="App">
      <button onClick={toggleDarkMode} className="absolute top-4 right-4 p-2 bg-gray-200 dark:bg-gray-700 rounded">
        {darkMode ? 'Light Mode' : 'Dark Mode'}
      </button>
      {token ? <Dashboard onLogout={handleLogout} /> : <Login onLogin={handleLogin} />}
    </div>
  );
};

export default App;